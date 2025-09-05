#!/usr/bin/env bash
set -Eeuo pipefail

ts() { date -u +"[%Y-%m-%d %H:%M:%S+0000]"; }
log_i() { echo "$(ts) INFO  $*"; }
log_ok(){ echo "$(ts) OK    $*"; }
log_w() { echo "$(ts) WARN  $*"; }
log_e() { echo "$(ts) ERROR $*" >&2; }

# Pretty section header
section(){ echo -e "\n==> $*"; }

# Wait until glusterd answers to CLI
wait_for_glusterd(){
  local tries="${1:-120}"
  local sleep_s="${2:-1}"
  section "Warte auf Readiness von glusterd"
  for ((i=1; i<=tries; i++)); do
    # FIX: Nicht 'glusterd' im Loop starten! Stattdessen CLI befragen:
    if gluster --mode=script --timeout=5 volume list >/dev/null 2>&1; then
      log_ok "glusterd ist bereit (Versuch $i)"
      return 0
    fi
    sleep "${sleep_s}"
  done

  log_e "glusterd nach ${tries}s nicht bereit."
  if [[ -f /var/log/glusterfs/glusterd.log ]]; then
    echo "=== letzte 200 Zeilen glusterd.log ==="
    tail -n 200 /var/log/glusterfs/glusterd.log || true
  elif [[ -f /gluster/logs/glusterd.log ]]; then
    echo "=== letzte 200 Zeilen glusterd.log ==="
    tail -n 200 /gluster/logs/glusterd.log || true
  else
    log_w "Kein glusterd.log gefunden unter /var/log/glusterfs oder /gluster/logs"
  fi
  return 1
}

require_dir(){
  local d="$1"
  [[ -d "$d" ]] || { mkdir -p "$d"; }
}

is_mounted(){
  # best-effort check; in einem Container kann ein Bind-Mount als rootfs erscheinen
  test -w "$1"
}
