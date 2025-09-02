#!/usr/bin/env bash
set -Eeuo pipefail

# ------------------------ pretty logging ------------------------
TS() { date +"%Y-%m-%d %H:%M:%S%z"; }
if [ -t 1 ]; then
  C_BOLD="\e[1m"; C_DIM="\e[2m"; C_RESET="\e[0m"
  C_BLUE="\e[34m"; C_GREEN="\e[32m"; C_YELLOW="\e[33m"; C_RED="\e[31m"; C_CYAN="\e[36m"; C_MAGENTA="\e[35m"
else
  C_BOLD=""; C_DIM=""; C_RESET=""; C_BLUE=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_CYAN=""; C_MAGENTA=""
fi
log()    { echo -e "[$(TS)] ${C_BLUE}INFO${C_RESET}  $*"; }
ok()     { echo -e "[$(TS)] ${C_GREEN}OK${C_RESET}    $*"; }
warn()   { echo -e "[$(TS)] ${C_YELLOW}WARN${C_RESET}  $*"; }
err()    { echo -e "[$(TS)] ${C_RED}ERROR${C_RESET} $*"; }
step()   { echo -e "\n${C_BOLD}${C_MAGENTA}==>${C_RESET} $*"; }

trap 'err "Abbruch (Exit-Code $?) an Zeile $LINENO"; exit 1' ERR

# ------------------------ config & defaults ------------------------
ROOT="${GLUSTER_ROOT:-/gluster}"
NODE="${GLUSTER_NODE:-$(hostname -s)}"
CONFIG="${GLUSTER_CONFIG:-$ROOT/etc/cluster.yml}"
AUTO_PROBE="${AUTO_PROBE_PEERS:-true}"
AUTO_CREATE="${AUTO_CREATE_VOLUMES:-false}"
MANAGER_NODE="${MANAGER_NODE:-}"
FAIL_ON_UNMOUNTED_BRICK="${FAIL_ON_UNMOUNTED_BRICK:-true}"
BRICKS_ENV="${BRICKS:-}"
ALLOW_SINGLE_BRICK="${ALLOW_SINGLE_BRICK:-false}"

# ------------------------ banner ------------------------
echo -e "${C_BOLD}${C_CYAN}
  GlusterFS Container Entrypoint
${C_RESET}"
log "Node-Name          : ${C_BOLD}${NODE}${C_RESET}"
log "Persistenz-Root    : ${C_BOLD}${ROOT}${C_RESET}"
log "YAML-Konfig        : ${C_BOLD}${CONFIG}${C_RESET}"
log "Peers auto-probe   : ${C_BOLD}${AUTO_PROBE}${C_RESET}"
log "Volumes auto-manage: ${C_BOLD}${AUTO_CREATE}${C_RESET}"
log "Manager-Node       : ${C_BOLD}${MANAGER_NODE:-<nicht gesetzt>}${C_RESET}"
log "Fail bei ungemount.: ${C_BOLD}${FAIL_ON_UNMOUNTED_BRICK}${C_RESET}"
log "Single-Brick erlaubt: ${C_BOLD}${ALLOW_SINGLE_BRICK}${C_RESET}"
[ -n "$BRICKS_ENV" ] && log "BRICKS (ENV)       : ${C_BOLD}${BRICKS_ENV}${C_RESET}"

# ------------------------ Vorbedingungen ------------------------
step "Verzeichnisstruktur & Basismount prüfen"
mkdir -p "$ROOT/etc" "$ROOT/glusterd" "$ROOT/logs" "$ROOT/bricks"
if mountpoint -q "$ROOT"; then ok "Persistenz-Mount erkannt: $ROOT"; else
  err "Persistenz-Mount $ROOT NICHT erkannt. Bitte Hostpfad z. B. mit -v /srv/gluster:$ROOT einhängen."; exit 1; fi

# Defaults seeden falls leer
if [ -z "$(ls -A "$ROOT/etc" 2>/dev/null || true)" ]; then
  step "Seede Default-Konfigurationen nach $ROOT/etc"
  cp -a /opt/glusterfs-defaults/. "$ROOT/etc"/; ok "Defaults kopiert"
else ok "Config-Verzeichnis bereits befüllt"; fi

# ------------------------ Bricks ermitteln ------------------------
step "Bricks ermitteln (YAML + ENV)"
declare -a BRICK_PATHS=()
if [[ -f "$CONFIG" ]]; then
  log "Lese YAML: $CONFIG"
  while IFS= read -r b; do [[ -n "$b" && "$b" != "null" ]] && BRICK_PATHS+=("$b"); done \
    < <(yq -r '.local_bricks[]? // empty' "$CONFIG")
else warn "Keine YAML-Konfig gefunden (optional): $CONFIG"; fi
if [[ -n "$BRICKS_ENV" ]]; then
  IFS=',' read -r -a extra <<< "$BRICKS_ENV"
  for raw in "${extra[@]}"; do b="$(echo "$raw" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -z "$b" || "$b" == "null" ]] && continue; BRICK_PATHS+=("$b"); done
fi
if ((${#BRICK_PATHS[@]} > 0)); then
  mapfile -t BRICK_PATHS < <(printf "%s\n" "${BRICK_PATHS[@]}" | awk '!seen[$0]++')
  ok "Gefundene Bricks (${#BRICK_PATHS[@]}):"; for b in "${BRICK_PATHS[@]}"; do echo "  - $b"; done
else warn "Keine Bricks angegeben. YAML .local_bricks oder ENV BRICKS verwenden."; fi

# ------------------------ Brick-Mounts prüfen ------------------------
step "Bricks anlegen & Bind-Mounts verifizieren"
for brick in "${BRICK_PATHS[@]}"; do
  mkdir -p "$brick"
  if mountpoint -q "$brick"; then ok "Brick gemountet: $brick"; else
    if [[ "$FAIL_ON_UNMOUNTED_BRICK" == "true" ]]; then
      err "Brick NICHT gemountet (Bind-Mount fehlt): $brick"
      err "Bitte Hostpfad einhängen, z. B.:  -v /data/vol1_brick:$brick"; exit 1
    else warn "Brick nicht gemountet, verwende Container-FS (nur Test): $brick"; fi
  fi
done

# ------------------------ glusterd starten ------------------------
step "Starte glusterd (Management-Daemon)"
/usr/sbin/glusterd & GLUSTERD_PID=$!
ok "glusterd PID: $GLUSTERD_PID"
for i in {1..20}; do pgrep -x glusterd >/dev/null 2>&1 && break || sleep 0.3; done
gluster --version >/dev/null 2>&1 && ok "Gluster CLI verfügbar"

# ------------------------ Peers probe (optional) ------------------------
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
else log "Peer-Probing übersprungen (kein YAML oder AUTO_PROBE_PEERS=false)"; fi

# ------------------------ Volumes verwalten (optional) ------------------------
# Helper: Safety-Checks für Volume-Definition
check_volume_safety() {
  local idx="$1" name="$2" vtype="$3"; shift 3
  local -a bricks=( "$@" )
  local n="${#bricks[@]}"

  # 1) Single-Brick-Guard (typisch distribute mit 1 Brick)
  if (( n == 1 )); then
    if [[ "$ALLOW_SINGLE_BRICK" == "true" ]]; then
      warn "Volume '${name}' hat NUR 1 Brick (kein Redundanz/Quorum). ALLOW_SINGLE_BRICK=true → fortsetzen."
    else
      err  "Volume '${name}' hat NUR 1 Brick (kein Redundanz/Quorum)."
      err  "Wenn du das bewusst willst (z. B. Test), setze: -e ALLOW_SINGLE_BRICK=true"
      err  "Besser: zweiten Brick (oder Replikation/Disperse) definieren."
      exit 42
    fi
  fi

  # 2) Replikations-Formalia
  if [[ "$vtype" == "replicate" ]]; then
    local replica arbiter; replica="$(yq -r ".volumes[$idx].replica // \"\"" "$CONFIG")"
    arbiter="$(yq -r ".volumes[$idx].arbiter // \"\"" "$CONFIG")"
    if [[ -z "$replica" || "$replica" == "null" ]]; then
      err "replicate-Volume '${name}' ohne 'replica' definiert."; exit 43
    fi
    # bricks müssen Vielfaches von replica sein
    if (( n % replica != 0 )); then
      err "replicate-Volume '${name}': Brick-Anzahl ($n) ist kein Vielfaches von replica ($replica)."; exit 44
    fi
    # optionale Plausibilitätswarnung für Arbiter
    if [[ -n "$arbiter" && "$arbiter" != "null" ]]; then
      if (( arbiter >= replica )); then
        warn "Arbiter ($arbiter) >= replica ($replica) bei '${name}' wirkt unplausibel – bitte prüfen."
      fi
    fi
  fi

  # 3) Disperse-Formalia
  if [[ "$vtype" == "disperse" ]]; then
    local disperse redundancy
    disperse="$(yq -r ".volumes[$idx].disperse_count // \"\"" "$CONFIG")"
    redundancy="$(yq -r ".volumes[$idx].redundancy // \"\"" "$CONFIG")"
    if [[ -z "$disperse" || -z "$redundancy" || "$disperse" == "null" || "$redundancy" == "null" ]]; then
      err "disperse-Volume '${name}' ohne 'disperse_count' und/oder 'redundancy'."; exit 45
    fi
    if (( n != disperse )); then
      err "disperse-Volume '${name}': Brick-Anzahl ($n) != disperse_count ($disperse)."; exit 46
    fi
    if (( redundancy <= 0 || redundancy >= disperse )); then
      warn "disperse-Volume '${name}': ungewöhnliche redundancy=$redundancy (0<redundancy<disperse empfohlen)."
    fi
  fi
}

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
      [[ -z "$name" || "$name" == "null" ]] && { warn "Volume ohne Namen übersprungen (Index $i)"; continue; }
      vtype="$(yq -r ".volumes[$i].type // \"distribute\"" "$CONFIG")"
      transport="$(yq -r ".volumes[$i].transport // \"tcp\"" "$CONFIG")"
      mapfile -t bricks < <(yq -r ".volumes[$i].bricks[]? // empty" "$CONFIG")
      if [[ ${#bricks[@]} -eq 0 ]]; then warn "Volume '$name' ohne bricks – übersprungen."; continue; fi

      # --- Safety-Checks vor dem Create ---
      check_volume_safety "$i" "$name" "$vtype" "${bricks[@]}"

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
            [[ -n "$disperse" && -n "$redundancy" && "$disperse" != "null" && "$redundancy" != "null" ]] \
              && cmd+=("disperse" "$disperse" "redundancy" "$redundancy")
            ;;
          distribute|*) ;;
        esac
        cmd+=("transport" "$transport"); cmd+=("${bricks[@]}")
        log "Erzeuge Volume mit Befehl:\n  ${C_DIM}${cmd[*]}${C_RESET}"
        "${cmd[@]}"
      fi

      # Optionen setzen
      yq -r ".volumes[$i].options // {} | to_entries[]? | \"\(.key) \(.value)\"" "$CONFIG" \
      | while read -r key val; do
          [[ -z "$key" || "$key" == "null" ]] && continue
          log "Setze Option: ${name} ${key}=${val}"
          gluster volume set "$name" "$key" "$val" || true
        done

      # Starten
      if gluster volume status "$name" >/dev/null 2>&1; then ok "Volume läuft: $name"; else
        log "Starte Volume: $name"; gluster volume start "$name" || true; fi
    done
  else warn "AUTO_CREATE_VOLUMES=true, aber keine YAML gefunden – nichts zu tun."; fi
else log "Volume-Management deaktiviert (AUTO_CREATE_VOLUMES=false)"; fi

# ------------------------ Übergabe an glusterd ------------------------
step "Läuft. Übergabe an glusterd (PID $GLUSTERD_PID) – Logs unter $ROOT/logs/"
wait "$GLUSTERD_PID"
