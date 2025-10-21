#!/usr/bin/env bash
set -Eeuo pipefail

# --- Config / Defaults ---
VOLUMES_YML="${VOLUMES_YML:-/etc/gluster/volumes.yml}"
SOLO_STARTUP="${SOLO_STARTUP:-auto}"   # auto|on|off
SOLO_CONDITION="${SOLO_CONDITION:-volumes_yml_exists}" # future: expand conditions
GLUSTERD_BIN="${GLUSTERD_BIN:-/usr/sbin/glusterd}"
GLUSTER_CLI="${GLUSTER_CLI:-/usr/sbin/gluster}"

# --- Helpers ---
log() { printf '[entrypoint] %s\n' "$*" >&2; }
die() { printf '[entrypoint:ERROR] %s\n' "$*" >&2; exit 1; }

wait_glusterd_ready() {
  local tries=${1:-60}
  local i=0
  until ${GLUSTER_CLI} --mode=script volume list >/dev/null 2>&1; do
    i=$((i+1))
    if (( i >= tries )); then
      return 1
    fi
    sleep 1
  done
  return 0
}

should_run_solo() {
  # Decide if solo-startup should run
  case "${SOLO_STARTUP}" in
    on) return 0 ;;
    off) return 1 ;;
    auto)
      if [[ "${SOLO_CONDITION}" == "volumes_yml_exists" && -s "${VOLUMES_YML}" ]]; then
        return 0
      fi
      return 1
      ;;
    *) log "Unbekannter SOLO_STARTUP=${SOLO_STARTUP}, benutze 'auto'";;
  esac
  return 1
}

# --- Start glusterd in Hintergrund, führe Solo-Setup aus, dann blockiere im Vordergrund ---
if [[ "${1:-}" == "glusterd" || "${1:-}" == "/usr/sbin/glusterd" ]]; then
  # Starte glusterd im Hintergrund, damit wir parallel konfigurieren können
  log "Starte glusterd im Hintergrund..."
  "${GLUSTERD_BIN}" -N &
  GLUSTERD_PID=$!
  trap 'log "Signal empfangen, sende SIGTERM an glusterd (${GLUSTERD_PID})"; kill -TERM ${GLUSTERD_PID} 2>/dev/null || true; wait ${GLUSTERD_PID} 2>/dev/null || true' TERM INT

  log "Warte auf CLI-Bereitschaft..."
  if ! wait_glusterd_ready 120; then
    die "glusterd CLI wurde nicht rechtzeitig bereit"
  fi

  if should_run_solo; then
    log "Solo-Startup-Bedingungen erfüllt – starte /entrypoints/solo-startup.py"
    /entrypoints/solo-startup.py "${VOLUMES_YML}" || die "solo-startup schlug fehl"
  else
    log "Solo-Startup nicht ausgeführt (SOLO_STARTUP=${SOLO_STARTUP}, SOLO_CONDITION=${SOLO_CONDITION}, VOLUMES_YML=${VOLUMES_YML})"
  fi

  log "EntryPoint wartet auf glusterd (${GLUSTERD_PID}) ..."
  wait ${GLUSTERD_PID}
  exit $?
fi

# Fallback: führe gewünschtes Kommando aus (z.B. Debug-Shell)
exec "$@"
