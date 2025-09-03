#!/usr/bin/env bash
set -Eeuo pipefail

# ---------- pretty logging ----------
TS() { date +"%Y-%m-%d %H:%M:%S%z"; }
if [ -t 1 ]; then
  C_BOLD="\e[1m"; C_DIM="\e[2m"; C_RESET="\e[0m"
  C_BLUE="\e[34m"; C_GREEN="\e[32m"; C_YELLOW="\e[33m"; C_RED="\e[31m"; C_CYAN="\e[36m"; C_MAGENTA="\e[35m"
else
  C_BOLD=""; C_DIM=""; C_RESET=""; C_BLUE=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_CYAN=""; C_MAGENTA=""
fi
log()  { echo -e "[$(TS)] ${C_BLUE}INFO${C_RESET}  $*"; }
ok()   { echo -e "[$(TS)] ${C_GREEN}OK${C_RESET}    $*"; }
warn() { echo -e "[$(TS)] ${C_YELLOW}WARN${C_RESET}  $*"; }
err()  { echo -e "[$(TS)] ${C_RED}ERROR${C_RESET} $*"; }
step() { echo -e "\n${C_BOLD}${C_MAGENTA}==>${C_RESET} $*"; }
trap 'err "Abbruch (Exit-Code $?) an Zeile $LINENO"; exit 1' ERR

# ---------- config ----------
ROOT="${GLUSTER_ROOT:-/gluster}"
NODE="${GLUSTER_NODE:-$(hostname -s)}"
CONFIG="${GLUSTER_CONFIG:-$ROOT/etc/cluster.yml}"
AUTO_PROBE="${AUTO_PROBE_PEERS:-true}"
AUTO_CREATE="${AUTO_CREATE_VOLUMES:-false}"
MANAGER_NODE="${MANAGER_NODE:-}"
FAIL_ON_UNMOUNTED_BRICK="${FAIL_ON_UNMOUNTED_BRICK:-true}"
BRICKS_ENV="${BRICKS:-}"
ALLOW_SINGLE_BRICK="${ALLOW_SINGLE_BRICK:-false}"

# Readiness + create retry + brick rewrite
GLUSTER_WAIT_TRIES="${GLUSTER_WAIT_TRIES:-60}"
GLUSTER_WAIT_SLEEP="${GLUSTER_WAIT_SLEEP:-1}"
CREATE_RETRIES="${CREATE_RETRIES:-10}"
CREATE_RETRY_SLEEP="${CREATE_RETRY_SLEEP:-2}"
REWRITE_LOCAL_BRICKS="${REWRITE_LOCAL_BRICKS:-true}"
GLUSTER_FORCE_CREATE="${GLUSTER_FORCE_CREATE:-false}"

echo -e "${C_BOLD}${C_CYAN}\n  GlusterFS Container Entrypoint\n${C_RESET}"
log "Node-Name            : ${C_BOLD}${NODE}${C_RESET}"
log "Persistenz-Root      : ${C_BOLD}${ROOT}${C_RESET}"
log "YAML-Konfig          : ${C_BOLD}${CONFIG}${C_RESET}"
log "Peers auto-probe     : ${C_BOLD}${AUTO_PROBE}${C_RESET}"
log "Volumes auto-manage  : ${C_BOLD}${AUTO_CREATE}${C_RESET}"
log "Manager-Node         : ${C_BOLD}${MANAGER_NODE:-<nicht gesetzt>}${C_RESET}"
log "Fail bei ungemount.  : ${C_BOLD}${FAIL_ON_UNMOUNTED_BRICK}${C_RESET}"
log "Single-Brick erlaubt : ${C_BOLD}${ALLOW_SINGLE_BRICK}${C_RESET}"
log "Wait(tries/sleep)    : ${C_BOLD}${GLUSTER_WAIT_TRIES}${C_RESET}/${C_BOLD}${GLUSTER_WAIT_SLEEP}${C_RESET}s"
log "Rewrite local bricks : ${C_BOLD}${REWRITE_LOCAL_BRICKS}${C_RESET}"
[ -n "$BRICKS_ENV" ] && log "BRICKS (ENV)         : ${C_BOLD}${BRICKS_ENV}${C_RESET}"

# ---------- prereqs ----------
step "Verzeichnisstruktur & Basismount prüfen"
mkdir -p "$ROOT/etc" "$ROOT/glusterd" "$ROOT/logs" "$ROOT/bricks"
if ! mountpoint -q "$ROOT"; then
  err "Persistenz-Mount $ROOT NICHT erkannt. Bitte mit -v /srv/gluster:$ROOT einhängen."
  exit 1
fi
ok "Persistenz-Mount erkannt: $ROOT"

if [ -z "$(ls -A "$ROOT/etc" 2>/dev/null || true)" ]; then
  step "Seede Default-Konfigurationen nach $ROOT/etc"
  cp -a /opt/glusterfs-defaults/. "$ROOT/etc"/
  ok "Defaults kopiert"
else
  ok "Config-Verzeichnis bereits befüllt"
fi

# ---------- brick list ----------
step "Bricks ermitteln (YAML + ENV)"
declare -a BRICK_PATHS=()
if [[ -f "$CONFIG" ]]; then
  log "Lese YAML: $CONFIG"
  while IFS= read -r b; do [[ -n "$b" && "$b" != "null" ]] && BRICK_PATHS+=("$b"); done \
    < <(yq -r '.local_bricks[]? // empty' "$CONFIG")
else
  warn "Keine YAML-Konfig gefunden (optional): $CONFIG"
fi
if [[ -n "$BRICKS_ENV" ]]; then
  IFS=',' read -r -a extra <<< "$BRICKS_ENV"
  for raw in "${extra[@]}"; do
    b="$(echo "$raw" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -z "$b" || "$b" == "null" ]] && continue
    BRICK_PATHS+=("$b")
  done
fi
if ((${#BRICK_PATHS[@]} > 0)); then
  mapfile -t BRICK_PATHS < <(printf "%s\n" "${BRICK_PATHS[@]}" | awk '!seen[$0]++')
  ok "Gefundene Bricks (${#BRICK_PATHS[@]}):"; for b in "${BRICK_PATHS[@]}"; do echo "  - $b"; done
else
  warn "Keine Bricks angegeben. YAML .local_bricks oder ENV BRICKS verwenden."
fi

step "Bricks anlegen & Bind-Mounts verifizieren"
for brick in "${BRICK_PATHS[@]}"; do
  mkdir -p "$brick"
  if mountpoint -q "$brick"; then ok "Brick gemountet: $brick"; else
    if [[ "$FAIL_ON_UNMOUNTED_BRICK" == "true" ]]; then
      err "Brick NICHT gemountet: $brick  (Host: -v /host/pfad:$brick)"; exit 1
    else
      warn "Brick nicht gemountet, verwende Container-FS (nur Test): $brick"
    fi
  fi
done

# ---------- glusterd start + readiness ----------
step "Starte glusterd (Management-Daemon)"
/usr/sbin/glusterd &
GLUSTERD_PID=$!
ok "glusterd PID: $GLUSTERD_PID"

wait_for_glusterd() {
  local tries="$GLUSTER_WAIT_TRIES" sleep_s="$GLUSTER_WAIT_SLEEP"
  for i in $(seq 1 "$tries"); do
    if gluster --mode=script volume list >/dev/null 2>&1 || gluster pool list >/dev/null 2>&1; then
      ok "glusterd ist bereit (Try $i/$tries)"
      return 0
    fi
    sleep "$sleep_s"
  done
  err "glusterd nach $(($tries * $sleep_s))s nicht bereit."
  echo "=== letzte 200 Zeilen glusterd.log ==="; tail -n 200 "$ROOT/logs/glusterd.log" || true
  exit 98
}
step "Warte auf Readiness von glusterd"
wait_for_glusterd
ok "Gluster CLI verfügbar"

# kleine Auflösungsdiagnose
SELF_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
RESOLVED_NODE_IP="$(getent hosts "$NODE" 2>/dev/null | awk '{print $1}' | head -1 || true)"
log "Self IP: ${SELF_IP:-<unk>}, ${NODE} → ${RESOLVED_NODE_IP:-<unk>}"

# ---------- peer probe ----------
if [[ -f "$CONFIG" && "$AUTO_PROBE" == "true" ]]; then
  step "Peers aus YAML proben"
  has_peer=false
  while IFS= read -r peer; do
    [[ -z "$peer" || "$peer" == "null" || "$peer" == "$NODE" ]] && continue
    has_peer=true
    for i in {1..10}; do
      if gluster peer probe "$peer" >/dev/null 2>&1; then ok "Peer geprobt: $peer"; break; fi
      warn "Peer probe fehlgeschlagen ($peer), Versuch $i/10 – erneut in 2s…"; sleep 2
    done
  done < <(yq -r '.peers[]? // empty' "$CONFIG")
  [[ "$has_peer" == false ]] && warn "Keine externen Peers in YAML gefunden (oder nur Self)."
else
  log "Peer-Probing übersprungen (kein YAML oder AUTO_PROBE_PEERS=false)"
fi

# ---------- safety checks ----------
check_volume_safety() {
  local idx="$1" name="$2" vtype="$3"; shift 3
  local -a bricks=( "$@" ); local n="${#bricks[@]}"
  if (( n == 1 )); then
    if [[ "$ALLOW_SINGLE_BRICK" == "true" ]]; then
      warn "Volume '${name}' hat NUR 1 Brick (kein Redundanz/Quorum). ALLOW_SINGLE_BRICK=true → fortsetzen."
    else
      err  "Volume '${name}' hat NUR 1 Brick. Setze -e ALLOW_SINGLE_BRICK=true oder füge Bricks hinzu."; exit 42
    fi
  fi
  if [[ "$vtype" == "replicate" ]]; then
    local replica arbiter; replica="$(yq -r ".volumes[$idx].replica // \"\"" "$CONFIG")"
    arbiter="$(yq -r ".volumes[$idx].arbiter // \"\"" "$CONFIG")"
    [[ -z "$replica" || "$replica" == "null" ]] && { err "replicate-Volume '${name}' ohne 'replica'"; exit 43; }
    (( n % replica == 0 )) || { err "replicate '${name}': Brick-Anzahl ($n) kein Vielfaches von replica ($replica)"; exit 44; }
    if [[ -n "$arbiter" && "$arbiter" != "null" && $arbiter -ge $replica ]]; then
      warn "Arbiter ($arbiter) >= replica ($replica) bei '${name}' – prüfen."
    fi
  fi
  if [[ "$vtype" == "disperse" ]]; then
    local disperse redundancy
    disperse="$(yq -r ".volumes[$idx].disperse_count // \"\"" "$CONFIG")"
    redundancy="$(yq -r ".volumes[$idx].redundancy // \"\"" "$CONFIG")"
    [[ -z "$disperse" || -z "$redundancy" || "$disperse" == "null" || "$redundancy" == "null" ]] && { err "disperse '${name}' ohne Parameter"; exit 45; }
    (( n == disperse )) || { err "disperse '${name}': Brick-Anzahl ($n) != disperse_count ($disperse)"; exit 46; }
  fi
}

# Helper: rewrite local bricks to SELF_IP (avoids name-resolution issues)
rewrite_local_bricks() {
  local -a in=( "$@" ) out=()
  for spec in "${in[@]}"; do
    local host="${spec%%:*}" path="${spec#*:}"
    if [[ "$REWRITE_LOCAL_BRICKS" == "true" && ( "$host" == "$NODE" || "$host" == "localhost" || "$host" == "$RESOLVED_NODE_IP" ) ]]; then
      local new="${SELF_IP:-$host}:$path"
      [[ "$new" != "$spec" ]] && log "Rewriting local brick host: $spec → $new"
      out+=( "$new" )
    else
      out+=( "$spec" )
    fi
  done
  printf "%s\n" "${out[@]}"
}

run_with_retry() {
  local tries="$1" sleep_s="$2"; shift 2
  local i
  for i in $(seq 1 "$tries"); do
    if "$@"; then return 0; fi
    warn "Command failed (try $i/$tries): $*"
    sleep "$sleep_s"
  done
  return 1
}

# ---------- volume management ----------
if [[ "$AUTO_CREATE" == "true" ]]; then
  step "Volume-Management (create/set/start)"
  [[ -z "$MANAGER_NODE" && -f "$CONFIG" ]] && MANAGER_NODE="$(yq -r '.manager_node // ""' "$CONFIG")"
  if [[ -n "$MANAGER_NODE" && "$MANAGER_NODE" != "$NODE" ]]; then
    log "Dieser Node ist NICHT der Manager (Manager: '$MANAGER_NODE') – überspringe Volume-Management."
  elif [[ -f "$CONFIG" ]]; then
    COUNT="$(yq -r '.volumes | length // 0' "$CONFIG" 2>/dev/null || echo 0)"
    log "Gefundene Volume-Definitionen: $COUNT"
    for ((i=0; i<COUNT; i++)); do
      name="$(yq -r ".volumes[$i].name" "$CONFIG")"
      [[ -z "$name" || "$name" == "null" ]] && { warn "Volume ohne Namen (Index $i) – skip"; continue; }
      vtype="$(yq -r ".volumes[$i].type // \"distribute\"" "$CONFIG")"
      transport="$(yq -r ".volumes[$i].transport // \"tcp\"" "$CONFIG")"
      mapfile -t bricks_raw < <(yq -r ".volumes[$i].bricks[]? // empty" "$CONFIG")
      (( ${#bricks_raw[@]} )) || { warn "Volume '$name' ohne bricks – skip"; continue; }

      # Safety + rewrite
      check_volume_safety "$i" "$name" "$vtype" "${bricks_raw[@]}"
      mapfile -t bricks < <(rewrite_local_bricks "${bricks_raw[@]}")

      if gluster volume info "$name" >/dev/null 2>&1; then
        ok "Volume existiert bereits: ${C_BOLD}$name${C_RESET} – setze Optionen & starte falls nötig."
      else
        cmd=(gluster volume create "$name")
        case "$vtype" in
          replicate)
            replica="$(yq -r ".volumes[$i].replica // \"\"" "$CONFIG")"
            arbiter="$(yq -r ".volumes[$i].arbiter // \"\"" "$CONFIG")"
            [[ -n "$replica" && "$replica" != "null" ]] && cmd+=("replica" "$replica")
            [[ -n "$arbiter" && "$arbiter" != "null" ]] && cmd+=("arbiter" "$arbiter")
            ;;
          disperse)
            disperse="$(yq -r ".volumes[$i].disperse_count // \"\"" "$CONFIG")"
            redundancy="$(yq -r ".volumes[$i].redundancy // \"\"" "$CONFIG")"
            [[ -n "$disperse" && -n "$redundancy" && "$disperse" != "null" && "$redundancy" != "null" ]] && cmd+=("disperse" "$disperse" "redundancy" "$redundancy")
            ;;
          distribute|*) ;;
        esac
        cmd+=("transport" "$transport")
        cmd+=("${bricks[@]}")
        [[ "$GLUSTER_FORCE_CREATE" == "true" ]] && cmd+=("force")
        log "Erzeuge Volume mit Befehl:\n  ${C_DIM}${cmd[*]}${C_RESET}"

        if ! run_with_retry "$CREATE_RETRIES" "$CREATE_RETRY_SLEEP" "${cmd[@]}"; then
          err "Volume-Create für '$name' scheitert nach ${CREATE_RETRIES} Versuchen."
          echo "=== letzte 200 Zeilen glusterd.log ==="; tail -n 200 "$ROOT/logs/glusterd.log" || true
          exit 97
        fi
      fi

      yq -r ".volumes[$i].options // {} | to_entries[]? | \"\(.key) \(.value)\"" "$CONFIG" \
      | while read -r key val; do
          [[ -z "$key" || "$key" == "null" ]] && continue
          log "Setze Option: ${name} ${key}=${val}"
          gluster volume set "$name" "$key" "$val" || true
        done

      if gluster volume status "$name" >/dev/null 2>&1; then
        ok "Volume läuft: $name"
      else
        log "Starte Volume: $name"; gluster volume start "$name" || true
      fi
    done
  else
    warn "AUTO_CREATE_VOLUMES=true, aber keine YAML gefunden – nichts zu tun."
  fi
else
  log "Volume-Management deaktiviert (AUTO_CREATE_VOLUMES=false)"
fi

step "Läuft. Übergabe an glusterd (PID $GLUSTERD_PID) – Logs unter $ROOT/logs/"
wait "$GLUSTERD_PID"
