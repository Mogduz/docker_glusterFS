# === [DOC] Autogenerierte Inline-Dokumentation: solo-start.sh ===
# Datei: entrypoints/solo-start.sh
# Typ: POSIX/Bash-Shellskript.
# Zweck: Steuerung/Bootstrap/Start des Gluster-Dienstes bzw. Solo-Setups.
# Wichtige Aspekte: Fehlerbehandlung (fatal/log), Umgebungsvariablen, Brick/Volume-Handling, YAML-Parsing.
# Erkannte Funktionen: log, fatal, require_vars, wait_glusterd, is_true, pick_hostname, emit_yaml_specs, volume_exists, volume_status_started, ensure_volume_started, apply_options_and_quota, check_hard_changes, create_or_update_volume_from_spec, log_volume_info, process_volumes_yaml
# Sicherheitsaspekte: Skript bricht bei Fehlern ab, prüft Pfade/Rechte, loggt diagnostische Infos.
# === [DOC-END] ===

#!/usr/bin/env bash
set -e
# enable pipefail and errtrace if supported (dash/posix-safe)
( set -o pipefail ) >/dev/null 2>&1 && set -o pipefail
( set -E ) >/dev/null 2>&1 && set -E
# --- Verbosity controls for solo-start ---
: "${VERBOSE:=1}"
: "${DEBUG:=0}"
if [ "${TRACE:-0}" = "1" ]; then set -x; fi

# --- portable fallback logger (defined early) ---
if ! command -v log >/dev/null 2>&1; then
  log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
fi
# ------------------------------------------------
info()  { log "INFO: $*"; }
warn()  { log "WARN: $*"; }
error() { log "ERROR: $*"; }
debug() { [ "$DEBUG" = "1" ] || [ "$VERBOSE" -ge 2 ] && log "DEBUG: $*"; :; }

log \"=== solo-start: begin ===\"

# >>> preflight variable checks (auto-inserted)
# Provide a local log() if not already defined by the caller (entrypoint.sh)
if ! command -v log >/dev/null 2>&1; then
# ---
# Funktion:   log() {()
# Beschreibung: Siehe Inline-Kommentare; verarbeitet Teilaspekte des Startups/Bootstraps.
# ---
  log() { printf '%s %s
' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
fi

# Log file for startup diagnostics
LOG_FILE="${LOG_FILE:-/var/log/gluster-entrypoint.log}"
# ---
# Funktion: 

# Beschreibung: Siehe Inline-Kommentare; verarbeitet Teilaspekte des Startups/Bootstraps.
# ---

fatal() {
  msg="$*"
  # Emit to stderr and append to log
  printf '%s ERROR: %s
' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$msg" | tee -a "$LOG_FILE" >&2
  exit 1
}
# ---
# Funktion: 

# Beschreibung: Siehe Inline-Kommentare; verarbeitet Teilaspekte des Startups/Bootstraps.
# ---

require_vars() {
  missing=""
  for var in "$@"; do
    eval "val=\${$var:-}"
    if [ -z "$val" ]; then
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

# === Volumes aus YAML einlesen und reconciliieren ============================
# Quelle festlegen: VOLUMES_YAML bevorzugt, sonst VOLUMES_FILE, sonst /etc/glusterfs/volumes.yml
: "${GLUSTER_BIN:=/usr/sbin/gluster}"
: "${GLUSTERD_BIN:=/usr/sbin/glusterd}"
VOLUMES_YAML="${VOLUMES_YAML:-${VOLUMES_FILE:-/etc/glusterfs/volumes.yml}}"

# Warten bis glusterd bereit ist
# ---
# Funktion: wait_glusterd() {()
# Beschreibung: Siehe Inline-Kommentare; verarbeitet Teilaspekte des Startups/Bootstraps.
# ---
wait_glusterd() {
  i=0; max=60
  until "$GLUSTER_BIN" --mode=script volume list >/dev/null 2>&1; do
    i=$((i+1))
    if [ "$i" -ge "$max" ]; then
      fatal "glusterd nicht erreichbar (timeout)"
    fi
    sleep 1
  done
  log "glusterd ist bereit"
}
# ---
# Funktion: 

# Beschreibung: Siehe Inline-Kommentare; verarbeitet Teilaspekte des Startups/Bootstraps.
# ---

is_true() {
  case "${1:-}" in
    1|yes|true|on|enable|enabled|TRUE|Yes|On) return 0 ;;
    *) return 1 ;;
  esac
}
# ---
# Funktion: 

# Beschreibung: Siehe Inline-Kommentare; verarbeitet Teilaspekte des Startups/Bootstraps.
# ---

pick_hostname() {
  if [ -n "${PRIVATE_IP:-}" ]; then
    printf '%s\n' "$PRIVATE_IP"
  else
    hostname -i 2>/dev/null | awk '{print $1}'
  fi
}

# AWK-basierter YAML-Emitter (aus entrypoint.sh übernommen, leicht angepasst)
# ---
# Funktion: emit_yaml_specs() {()
# Beschreibung: Siehe Inline-Kommentare; verarbeitet Teilaspekte des Startups/Bootstraps.
# ---
emit_yaml_specs() {
    file="$1"
    [ -s "$file" ] || return 1
    awk '
        function ltrim(s){ sub(/^\s+/, "", s); return s }
        function rtrim(s){ sub(/\s+$/, "", s); return s }
        function trim(s){ return rtrim(ltrim(s)) }
        BEGIN{ in_vols=0; in_vol=0; sect=""; sect_indent=-1; }
        /^[[:space:]]*#/ { next }    # skip comments
        /^[[:space:]]*$/ { next }    # skip empty
        /^volumes:[[:space:]]*$/ { in_vols=1; next }
        {
            line=$0
            indent=match(line,/[^ ]/) - 1
            gsub(/^[ ]+/, "", line)
            if (in_vols==0) next

            if (match(line, /^-[ ]+name:[ ]*(.*)$/, a)) {
                if (in_vol==1) {
                    print "__END_VOL__"
                }
                print "__BEGIN_VOL__"
                print "VOLNAME=" a[1]
                in_vol=1
                next
            }

            if (in_vol==1) {
                if (match(line, /^replica:[ ]*([0-9]+)/, a))  { print "REPLICA=" a[1]; next }
                if (match(line, /^transport:[ ]*([a-zA-Z0-9_-]+)/, a)) { print "TRANSPORT=" a[1]; next }
                if (match(line, /^auth_allow:[ ]*(.*)$/, a))   { print "AUTH_ALLOW=" a[1]; next }
                if (match(line, /^nfs_disable:[ ]*(.*)$/, a))   { print "NFS_DISABLE=" a[1]; next }
                if (match(line, /^options_reset:[ ]*(.*)$/, a)) { print "OPTIONS_RESET=" a[1]; next }
                if (match(line, /^quota:[ ]*$/)) { sect="quota"; sect_indent=indent; next }
                if (match(line, /^options:[ ]*$/)) { sect="options"; sect_indent=indent; next }

                if (sect=="quota") {
                    if (indent<=sect_indent) { sect=""; sect_indent=-1 }
                    else {
                        if (match(line, /^limit:[ ]*(.*)$/, a)) { print "YAML_QUOTA_LIMIT=" a[1]; next }
                        if (match(line, /^soft_limit_pct:[ ]*([0-9]+)/, a)) { print "YAML_QUOTA_SOFT=" a[1]; next }
                    }
                }
                if (sect=="options") {
                    if (indent<=sect_indent) { sect=""; sect_indent=-1 }
                    else {
                        if (match(line, /^([a-zA-Z0-9._-]+):[ ]*(.*)$/, a)) {
                            key=a[1]; val=a[2]
                            print "VOL_OPT " key "=" val
                            next
                        }
                    }
                }
            }
        }
        END { if (in_vol==1) print "__END_VOL__" }
    ' "$file"
}
# ---
# Funktion: 

# Beschreibung: Siehe Inline-Kommentare; verarbeitet Teilaspekte des Startups/Bootstraps.
# ---

volume_exists() {
  "$GLUSTER_BIN" --mode=script volume info "$1" >/dev/null 2>&1
}
# ---
# Funktion: 

# Beschreibung: Siehe Inline-Kommentare; verarbeitet Teilaspekte des Startups/Bootstraps.
# ---

volume_status_started() {
  "$GLUSTER_BIN" --mode=script volume info "$1" 2>/dev/null | awk -F': ' '/^Status:/ {print $2}' | grep -qi '^Started$'
}
# ---
# Funktion: ensure_volume_started() {()
# Beschreibung: Siehe Inline-Kommentare; verarbeitet Teilaspekte des Startups/Bootstraps.
# ---
ensure_volume_started() {
  vol="$1"
  if volume_status_started "$vol"; then
    log "Volume $vol ist bereits gestartet"
    log_volume_info "$vol"
  else
    log "Starte Volume $vol"
    "$GLUSTER_BIN" volume start "$vol" force >/dev/null 2>&1 || fatal "Konnte Volume $vol nicht starten"
    # kurze Wartezeit, dann erneut prüfen
    sleep 1
    if volume_status_started "$vol"; then
      log "Volume $vol erfolgreich gestartet"
      log_volume_info "$vol"
    else
      # letzte Info zur Diagnose
      log_volume_info "$vol"
      fatal "Volume $vol ließ sich nicht in den Status 'Started' bringen"
    fi
  fi
}
# ---
# Funktion: 

# Beschreibung: Siehe Inline-Kommentare; verarbeitet Teilaspekte des Startups/Bootstraps.
# ---

apply_options_and_quota() {
  vol="$1"
  # VOL_OPTS: kommasepariert key=value
  if [ -n "${VOL_OPTS:-}" ]; then
    IFS=, ; set -- $VOL_OPTS ; unset IFS
    for kv in "$@"; do
      [ -n "$kv" ] || continue
      key="${kv%%=*}"; val="${kv#*=}"
      log "Setze Option auf $vol: $key=$val"
      "$GLUSTER_BIN" volume set "$vol" "$key" "$val" >/dev/null 2>&1 || warn "Konnte $key auf $vol nicht setzen"
    done
  fi

  # Reset einzelner Optionen (CSV)
  if [ -n "${OPTIONS_RESET:-}" ]; then
    IFS=, ; set -- $OPTIONS_RESET ; unset IFS
    for key in "$@"; do
      [ -n "$key" ] || continue
      log "Resette Option auf $vol: $key"
      "$GLUSTER_BIN" volume reset "$vol" "$key" >/dev/null 2>&1 || warn "Konnte $key auf $vol nicht resetten"
    done
  fi

  # auth.allow und nfs.disable
  if [ -n "${AUTH_ALLOW:-}" ]; then
    # leere Zeichenkette bedeutet reset
    if [ "$AUTH_ALLOW" = '""' ] || [ "$AUTH_ALLOW" = "''" ]; then
      log "Resette auth.allow auf $vol (leer in YAML)"
      "$GLUSTER_BIN" volume reset "$vol" auth.allow >/dev/null 2>&1 || warn "auth.allow reset fehlgeschlagen"
    else
      log "Setze auth.allow auf $vol: $AUTH_ALLOW"
      "$GLUSTER_BIN" volume set "$vol" auth.allow "$AUTH_ALLOW" >/dev/null 2>&1 || warn "auth.allow setzen fehlgeschlagen"
    fi
  fi
  if [ -n "${NFS_DISABLE:-}" ]; then
    state="$(is_true "$NFS_DISABLE" && printf on || printf off)"
    log "Setze nfs.disable=$state auf $vol"
    "$GLUSTER_BIN" volume set "$vol" nfs.disable "$state" >/dev/null 2>&1 || warn "nfs.disable setzen fehlgeschlagen"
  fi

  # Quota
  if [ -n "${YAML_QUOTA_LIMIT:-}" ]; then
    log "Aktiviere/konfiguriere Quota auf $vol"
    "$GLUSTER_BIN" volume quota "$vol" enable >/dev/null 2>&1 || warn "quota enable failed auf $vol (evtl. schon aktiv)"
    "$GLUSTER_BIN" volume quota "$vol" limit-usage / "$YAML_QUOTA_LIMIT" >/dev/null 2>&1 || warn "quota limit-usage failed auf $vol"
    if [ -n "${YAML_QUOTA_SOFT:-}" ]; then
      "$GLUSTER_BIN" volume set "$vol" features.soft-limit "${YAML_QUOTA_SOFT}%" >/dev/null 2>&1 || warn "soft-limit setzen fehlgeschlagen"
    fi
  fi
}

# Abgleich „harte“ Änderungen: replica/transport/bricks werden nur geprüft und geloggt
# ---
# Funktion: check_hard_changes() {()
# Beschreibung: Siehe Inline-Kommentare; verarbeitet Teilaspekte des Startups/Bootstraps.
# ---
check_hard_changes() {
  vol="$1"
  changes=0
  cur_info="$("$GLUSTER_BIN" --mode=script volume info "$vol" 2>/dev/null)"
  cur_rep="$(printf '%s\n' "$cur_info" | awk -F': ' '/^Number of Bricks:/ {print $2}' | awk "{print \$1}")"
  cur_trans="$(printf '%s\n' "$cur_info" | awk -F': ' '/^Transport-type:/ {print $2}' | tr -d "[:space:]")"
  # Hinweis: exakte Brick-Liste vergleichen wäre komplex; wir loggen nur.
  if [ -n "${REPLICA:-}" ] && [ -n "$cur_rep" ] && [ "$REPLICA" != "$cur_rep" ]; then
    warn "Replica-Änderung erkannt ($cur_rep → $REPLICA) auf $vol – automatische Anpassung wird NICHT durchgeführt."
    changes=1
  fi
  if [ -n "${TRANSPORT:-}" ] && [ -n "$cur_trans" ] && [ "$TRANSPORT" != "$cur_trans" ]; then
    warn "Transport-Änderung erkannt ($cur_trans → $TRANSPORT) auf $vol – automatische Anpassung wird NICHT durchgeführt."
    changes=1
  fi
  return $changes
}
# ---
# Funktion: 

# Beschreibung: Siehe Inline-Kommentare; verarbeitet Teilaspekte des Startups/Bootstraps.
# ---

create_or_update_volume_from_spec() {
  # Erwartet: VOLNAME, REPLICA, TRANSPORT, AUTH_ALLOW, NFS_DISABLE, VOL_OPTS, OPTIONS_RESET, YAML_QUOTA_LIMIT, YAML_QUOTA_SOFT
  : "${VOLNAME:?VOLNAME ist leer – YAML fehlerhaft?}"
  REPLICA="${REPLICA:-2}"
  TRANSPORT="${TRANSPORT:-tcp}"

  if ! volume_exists "$VOLNAME"; then
    log "Volume $VOLNAME existiert nicht – wird erstellt"
    host="$(pick_hostname)"
    # BRICK_DIRS muss vorhanden/validiert sein (kommt aus Brick-Ermittlung weiter oben)
    spec=""
    for b in $BRICK_DIRS; do
      mkdir -p "$b/$VOLNAME" || fatal "Kann Brick-Subdir nicht anlegen: $b/$VOLNAME"
      spec="$spec ${host}:${b}/${VOLNAME}"
    done

    log "Erzeuge Volume: $VOLNAME (replica=$REPLICA transport=$TRANSPORT)"
      log "  bricks:"
      printf '    - %s
' $bricks
      log "  options: ${VOL_OPTS:-<none>}" 
    "$GLUSTER_BIN" volume create "$VOLNAME" replica "$REPLICA" transport "$TRANSPORT" $spec force >/dev/null 2>&1 \
      || fatal "Volume-Erstellung fehlgeschlagen: $VOLNAME"

    apply_options_and_quota "$VOLNAME"
    ensure_volume_started "$VOLNAME"
  else
    log "Volume $VOLNAME vorhanden – wird geprüft/aktualisiert"
    check_hard_changes "$VOLNAME" || true
    apply_options_and_quota "$VOLNAME"
    ensure_volume_started "$VOLNAME"
  fi
}
# ---
# Funktion: 

# Beschreibung: Siehe Inline-Kommentare; verarbeitet Teilaspekte des Startups/Bootstraps.
# ---

log_volume_info() {
  vol="$1"
  info="$("$GLUSTER_BIN" --mode=script volume info "$vol" 2>/dev/null)" || { warn "Konnte volume info für $vol nicht abrufen"; return 1; }

  # Keyfelder extrahieren
  status="$(printf '%s\n' "$info" | awk -F': ' '/^Status:/ {print $2; exit}')"
  bricks_count="$(printf '%s\n' "$info" | awk -F': ' '/^Number of Bricks:/ {print $2; exit}' | awk '{print $1}')"
  transport="$(printf '%s\n' "$info" | awk -F': ' '/^Transport-type:/ {print $2; exit}' | tr -d '[:space:]')"

  # Kurzinfo in normale Logs
  log "Volume-Info: name=$vol status=${status:-unknown} bricks=${bricks_count:-?} transport=${transport:-?}"

  # Vollständige Info in die Log-Datei kippen, mit Zeitstempel pro Zeile
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  {
    printf '%s INFO: ----- Volume Info BEGIN: %s -----\n' "$ts" "$vol"
    printf '%s INFO: %s\n' "$ts" "$(echo "$info" | head -n1)"
    # Prefix jede Zeile
    printf '%s\n' "$info" | while IFS= read -r ln; do
      printf '%s INFO: %s\n' "$ts" "$ln"
    done
    printf '%s INFO: ----- Volume Info END: %s -----\n' "$ts" "$vol"
  } >> "${LOG_FILE:-/var/log/gluster-entrypoint.log}" 2>/dev/null || true
}
# ---
# Funktion: 

# Beschreibung: Siehe Inline-Kommentare; verarbeitet Teilaspekte des Startups/Bootstraps.
# ---

process_volumes_yaml() {
  [ -r "$VOLUMES_YAML" ] || fatal "VOLUMES_YAML='$VOLUMES_YAML' nicht lesbar"
  log "Lese YAML-Spezifikation: $VOLUMES_YAML"
  # Sammle Optionen für jedes Volume
  VOL_OPTS=""
  emit_yaml_specs "$VOLUMES_YAML" | while IFS= read -r line; do
    case "$line" in
      __BEGIN_VOL__)
        VOLNAME=""; REPLICA=""; TRANSPORT=""; AUTH_ALLOW=""; NFS_DISABLE=""; VOL_OPTS=""; OPTIONS_RESET=""; YAML_QUOTA_LIMIT=""; YAML_QUOTA_SOFT=""
        ;;
      VOL_OPT*)
        kv="${line#VOL_OPT }"
        if [ -z "$VOL_OPTS" ]; then VOL_OPTS="$kv"; else VOL_OPTS="$VOL_OPTS,$kv"; fi
        ;;
      __END_VOL__)
        create_or_update_volume_from_spec
        ;;
      *)
        # direkte Zuweisungen wie KEY=VAL aus emit_yaml_specs
        eval "$line"
        ;;
    esac
  done
}

wait_glusterd
process_volumes_yaml
# === Ende Volumes/YAML ========================================================

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

describe_dir "$d"
# Jetzt, NACH der erfolgreichen Verifikation, sind die Bricks garantiert vorhanden
BRICKS_READY=true

# Bool für Volume-Init/Startup: Wenn neue Bricks erzeugt wurden, Bootstrap signalisieren
if [ "${BRICKS_CREATED}" = "true" ]; then
  VOL_BOOTSTRAP=true
  log "Neue Bricks angelegt → VOL_BOOTSTRAP=true"
fi

export BRICK_DIRS BRICKS_CREATED BRICKS_READY VOL_BOOTSTRAP
# --- Ende Brick-Ermittlung ---------------------------------------------------- ----------------------------------------------------