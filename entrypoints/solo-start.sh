#!/usr/bin/env bash
set -Eeo pipefail

# >>> preflight variable checks (auto-inserted)
# Provide a local log() if not already defined by the caller (entrypoint.sh)
if ! command -v log >/dev/null 2>&1; then
  log() { printf '%s %s
' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
fi

# Log file for startup diagnostics
LOG_FILE="${LOG_FILE:-/var/log/gluster-entrypoint.log}"

fatal() {
  msg="$*"
  # Emit to stderr and append to log
  printf '%s ERROR: %s
' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$msg" | tee -a "$LOG_FILE" >&2
  exit 1
}

require_vars() {
  missing=""
  for var in "$@"; do
    # ${!var} expands the variable named by $var
    if [ -z "${!var:-}" ]; then
      missing="$missing $var"
    fi
  done
  if [ -n "$missing" ]; then
    fatal "Fehlende Pflicht-Variable(n):$missing"
  fi
}

# Define the set of wirklich benötigte Variablen je nach Modus.
# Für 'solo' sind keine zwingend – wir prüfen aber konsistente Optionen.
if [ -n "${VOLUMES_YAML:-}" ]; then
  require_vars VOLUMES_YAML
  [ -r "$VOLUMES_YAML" ] || fatal "VOLUMES_YAML='$VOLUMES_YAML' ist nicht lesbar."
  [ -s "$VOLUMES_YAML" ] || fatal "VOLUMES_YAML='$VOLUMES_YAML' ist leer."
  log "VOLUMES_YAML erkannt: $VOLUMES_YAML"
fi

# Validierung: REPLICA muss eine positive Ganzzahl sein, falls gesetzt
if [ -n "${REPLICA:-}" ]; then
  case "$REPLICA" in
    *[!0-9]*) fatal "REPLICA muss eine positive Ganzzahl sein (aktuell: '$REPLICA')." ;;
    0) fatal "REPLICA darf nicht 0 sein." ;;
  esac
fi

# Sicherstellen, dass /bricks existiert und beschreibbar ist
mkdir -p /bricks 2>/dev/null || true
[ -w /bricks ] || fatal "/bricks ist nicht beschreibbar – bitte Volume-Mount oder Rechte prüfen."

# Optional: PRIVATE_IP Plausibilität (falls gesetzt)
if [ -n "${PRIVATE_IP:-}" ]; then
  case "$PRIVATE_IP" in
    ''|*[!0-9.]*|*.*.*.*.*) fatal "PRIVATE_IP ('$PRIVATE_IP') sieht nicht nach einer IPv4-Adresse aus." ;;
  esac
fi
# <<< preflight variable checks (auto-inserted)

# Solo mode startup extracted from entrypoint.sh
# This script expects the same environment variables that entrypoint.sh provides.

# shellcheck disable=SC2154
            : "${REPLICA:=2}"
            log "No bricks discovered; creating $REPLICA default bricks under /bricks"
            bricks=""
            i=1
            while [ "$i" -le "$REPLICA" ]; do
                d="/bricks/brick${i}"
                mkdir -p "$d"
                bricks="$bricks $d"
                i=$((i+1))
            done
            bricks="$(printf '%s\n' $bricks)"