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
# --- Brick-Ermittlung & -Anlage ----------------------------------------------
# Unterstützte Eingabe:
#   - BRICKS=" /path/one /path/two ..."   (durch Leerzeichen getrennt)
#   - Falls BRICKS leer: Default-Pfade /bricks/brick{1..REPLICA}
#
# Ergebnis:
#   - BRICK_DIRS : Liste der Ziel-Verzeichnisse (newline-separiert)
#   - BRICKS_CREATED=true|false : ob mindestens ein Brick angelegt wurde
#   - BRICKS_READY=true|false   : wird NUR gesetzt, wenn alle Bricks vorhanden & beschreibbar sind
#   - VOL_BOOTSTRAP=true        : wird gesetzt, wenn neue Bricks angelegt wurden
# -----------------------------------------------------------------------------
BRICKS_CREATED=false
BRICKS_READY=false

# Quellen bestimmen
if [ -n "${BRICKS:-}" ]; then
  log "Explizite BRICKS erkannt: $BRICKS"
  _brick_targets="$BRICKS"
else
  : "${REPLICA:=2}"
  log "Keine expliziten BRICKS; verwende Default für REPLICA=$REPLICA unter /bricks"
  _brick_targets=""
  i=1
  while [ "$i" -le "$REPLICA" ]; do
    _brick_targets="$_brick_targets /bricks/brick${i}"
    i=$((i+1))
  done
fi

# Normalisieren in newline-Liste
BRICK_DIRS="$(printf '%s\n' $_brick_targets)"

# Prüfen/Erstellen (Pass 1): fehlende Bricks anlegen
for d in $BRICK_DIRS; do
  if [ -d "$d" ]; then
    [ -w "$d" ] || fatal "Brick-Verzeichnis existiert, ist aber nicht beschreibbar: $d"
    log "Brick vorhanden: $d"
  else
    log "Brick fehlt; lege an: $d"
    mkdir -p "$d" || fatal "Kann Brick-Verzeichnis nicht anlegen: $d"
    BRICKS_CREATED=true
  fi
done

# Prüfen (Pass 2): Nach Anlage sicherstellen, dass ALLE Bricks existieren & beschreibbar sind
for d in $BRICK_DIRS; do
  [ -d "$d" ] && [ -w "$d" ] || fatal "Brick-Verzeichnis fehlt oder ist nicht beschreibbar: $d"
done

# Jetzt, NACH der erfolgreichen Verifikation, sind die Bricks garantiert vorhanden
BRICKS_READY=true

# Bool für Volume-Init/Startup: Wenn neue Bricks erzeugt wurden, Bootstrap signalisieren
if [ "${BRICKS_CREATED}" = "true" ]; then
  VOL_BOOTSTRAP=true
  log "Neue Bricks angelegt → VOL_BOOTSTRAP=true"
fi

export BRICK_DIRS BRICKS_CREATED BRICKS_READY VOL_BOOTSTRAP
# --- Ende Brick-Ermittlung ---------------------------------------------------- ----------------------------------------------------