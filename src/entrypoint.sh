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
[ -n "$BRICKS_ENV" ] && log "BRICKS (ENV)       : ${C_BOLD}${BRICKS_ENV}${C_RESET}"

# ------------------------ Vorbedingungen ------------------------
step "Verzeichnisstruktur & Basismount prüfen"
mkdir -p "$ROOT/etc" "$ROOT/glusterd" "$ROOT/logs" "$ROOT/bricks"

if mountpoint -q "$ROOT"; then
  ok "Persistenz-Mount erkannt: $ROOT"
else
  err "Persistenz-Mount $ROOT NICHT erkannt. Bitte Hostpfad z. B. mit -v /srv/gluster:$ROOT einhängen."
  exit 1
fi

# Defaults in /gluster/etc seeden, wenn leer
if [ -z "$(ls -A "$ROOT/etc" 2>/dev/null || true)" ]; then
  step "Seede Default-Konfigurationen nach $ROOT/etc"
  cp -a /opt/glusterfs-defaults/. "$ROOT/etc"/
  ok "Defaults kopiert"
else
  ok "Config-Verzeichnis bereits befüllt"
fi

# ------------------------ Brickliste zusammenstellen ------------------------
step "Bricks ermitteln (YAML + ENV)"
declare -a BRICK_PATHS=()

if [[ -f "$CONFIG" ]]; then
  log "Lese YAML: $CONFIG"
  while IFS= read -r b; do
    [[ -n "$b" && "$b" != "null" ]] && BRICK_PATHS+=("$b")
  done < <(yq -r '.local_bricks[]? // empty' "$CONFIG")
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

# Duplikate entfernen
if ((${#BRICK_PATHS[@]} > 0)); then
  mapfile -t BRICK_PATHS < <(printf "%s\n" "${BRICK_PATHS[@]}" | awk '!seen[$0]++')
  ok "Gefundene Bricks (${#BRICK_PATHS[@]}):"
  for b in "${BRICK_PATHS[@]}"; do echo "  - $b"; done
else
  warn "Keine Bricks angegeben. Du kannst sie in der YAML unter .local_bricks oder via ENV BRICKS definieren."
fi

# ------------------------ Brick-Mounts prüfen ------------------------
step "Bricks anlegen & Bind-Mounts verifizieren"
for brick in "${BRICK_PATHS[@]}"; do
  mkdir -p "$brick"
  if mountpoint -q "$brick"; then
    ok "Brick gemountet: $brick"
  else
    if [[ "$FAIL_ON_UNMOUNTED_BRICK" == "true" ]]; then
      err "Brick NICHT gemountet (Bind-Mount fehlt): $brick"
      err "Bitte Hostpfad einhängen, z. B.:  -v /data/vol1_brick:$brick"
      exit 1
    else
      warn "Brick nicht gemountet, verwende Container-FS (nur zu Testzwecken): $brick"
    fi
  fi
done

# ------------------------ glusterd starten ------------------------
step "Starte glusterd (Management-Daemon)"
/usr/sbin/glusterd &
GLUSTERD_PID=$!
ok "glusterd PID: $GLUSTERD_PID"

# kurz warten, bis CLI/Daemon sprechen
for i in {1..20}; do
  if pgrep -x glusterd >/dev/null 2>&1; then break; fi
  sleep 0.3
done
# ein leichtes CLI-Ping – erlaubt Fehler, wir wollen nur Aktivität sehen
if gluster --version >/dev/null 2>&1; then
  ok "Gluster CLI verfügbar"
fi

# ------------------------ Peers probe (optional) ------------------------
if [[ -f "$CONFIG" && "$AUTO_PROBE" == "true" ]]; then
  step "Peers aus YAML proben"
  has_peer=false
  while IFS= read -r peer; do
    [[ -z "$peer" || "$peer" == "null" || "$peer" == "$NODE" ]] && continue
    has_peer=true
    for i in {1..10}; do
      if gluster peer probe "$peer" >/dev/null 2>&1; then
        ok "Peer geprobt: $peer"
        break
      fi
      warn "Peer probe fehlgeschlagen ($peer), Versuch $i/10 – erneut in 2s…"
      sleep 2
    done
  done < <(yq -r '.peers[]? // empty' "$CONFIG")
  [[ "$has_peer" == false ]] && warn "Keine externen Peers in YAML gefunden (oder nur Self)."
else
  log "Peer-Probing übersprungen (kein YAML oder AUTO_PROBE_PEERS=false)"
fi

# ------------------------ Volumes verwalten (optional) ------------------------
if [[ "$AUTO_CREATE" == "true" ]]; then
  step "Volume-Management (create/set/start)"
  # Manager bestimmen
  if [[ -z "$MANAGER_NODE" && -f "$CONFIG" ]]; then
    MANAGER_NODE="$(yq -r '.manager_node // ""' "$CONFIG")"
  fi

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
      if [[ ${#bricks[@]} -eq 0 ]]; then
        warn "Volume '$name' ohne bricks – übersprungen."; continue
      fi

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
            if [[ -n "$disperse" && -n "$redundancy" && "$disperse" != "null" && "$redundancy" != "null" ]]; then
              cmd+=("disperse" "$disperse" "redundancy" "$redundancy")
            fi
            ;;
          distribute|*) ;;
        esac
        cmd+=("transport" "$transport")
        cmd+=("${bricks[@]}")
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
      if gluster volume status "$name" >/dev/null 2>&1; then
        ok "Volume läuft: $name"
      else
        log "Starte Volume: $name"
        gluster volume start "$name" || true
      fi
    done
  else
    warn "AUTO_CREATE_VOLUMES=true, aber keine YAML gefunden – nichts zu tun."
  fi
else
  log "Volume-Management deaktiviert (AUTO_CREATE_VOLUMES=false)"
fi

# ------------------------ Übergabe an glusterd im Vordergrund ------------------------
step "Läuft. Übergabe an glusterd (PID $GLUSTERD_PID) – Logs unter $ROOT/logs/"
wait "$GLUSTERD_PID"
