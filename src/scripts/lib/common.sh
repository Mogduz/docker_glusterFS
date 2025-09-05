#!/usr/bin/env bash
set -Eeuo pipefail

ts() { date -u +"[%Y-%m-%d %H:%M:%S+0000]"; }
log_i() { echo "$(ts) INFO  $*"; }
log_ok(){ echo "$(ts) OK    $*"; }
log_w() { echo "$(ts) WARN  $*"; }
log_e() { echo "$(ts) ERROR $*" >&2; }

# Abschnitts-Header
section(){ echo -e "\n==> $*"; }

# ----- Readiness für glusterd (per CLI prüfen, nicht glusterd im Loop starten!)
wait_for_glusterd(){
  local tries="${1:-120}"
  local sleep_s="${2:-1}"
  section "Warte auf Readiness von glusterd"
  for ((i=1; i<=tries; i++)); do
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

# Warten bis die Gluster-„Store“-Datei existiert (erster Start erzeugt diese)
wait_for_glusterd_store(){
  local tries="${1:-60}" sleep_s="${2:-0.5}"
  for ((i=1;i<=tries;i++)); do
    [[ -s /var/lib/glusterd/glusterd.info ]] && { log_ok "glusterd.info vorhanden"; return 0; }
    sleep "${sleep_s}"
  done
  log_w "glusterd.info nach $((tries*sleep_s))s noch nicht vorhanden – fahre fort."
  return 0
}

require_dir(){
  local d="$1"
  [[ -d "$d" ]] || { mkdir -p "$d"; }
}

is_mounted(){
  # best-effort; in Containern erscheinen Binds teils als rootfs – Schreibhaken genügt
  test -w "$1"
}

# ====================== YAML-Helper (yq) ======================
yaml_get_peers(){
  local file="${1:-/gluster/etc/cluster.yml}"
  [[ -s "$file" ]] || return 1
  yq -r '(.cluster.peers // .peers // [])[]? // empty' "$file" 2>/dev/null || true
}

yaml_get_vol_names(){
  local file="${1:-/gluster/etc/cluster.yml}"
  [[ -s "$file" ]] || return 1
  yq -r '(.cluster.volumes // .volumes // [])[].name // empty' "$file" 2>/dev/null || true
}

yaml_get_vol_field(){
  local file="$1" ; local vname="$2" ; local field="$3"
  yq -r "( .cluster.volumes // .volumes // [] )
         | map(select(.name == \"$vname\")) | .[0].$field // empty" "$file" 2>/dev/null || true
}

yaml_get_vol_bricks(){
  local file="$1" ; local vname="$2"
  yq -r "( .cluster.volumes // .volumes // [] )
         | map(select(.name == \"$vname\")) | .[0].bricks[]? // empty" "$file" 2>/dev/null || true
}

yaml_get_bricks_legacy(){
  local file="${1:-/gluster/etc/cluster.yml}"
  [[ -s "$file" ]] || return 1
  yq -r '(.cluster.bricks // .bricks // [])[]? // empty' "$file" 2>/dev/null || true
}

# ====================== Gluster-Helper ======================
gluster_pool_has(){
  local host="$1"
  # Suche Host in Pool-Liste (Hostname-Spalte)
  gluster pool list 2>/dev/null | awk 'NR>1 {print $3,$2}' | grep -E "(^|[[:space:]])${host}([[:space:]]|$)" -q
}

gluster_peer_probe(){
  local host="$1"
  if gluster_pool_has "$host"; then
    log_ok "Peer bereits verbunden: $host"
    return 0
  fi
  log_i "Peer probe: $host"
  gluster peer probe "$host" >/dev/null 2>&1 || true
}

wait_peer_connected(){
  local host="$1" ; local tries="${2:-60}" ; local sleep_s="${3:-1}"
  for ((i=1; i<=tries; i++)); do
    if gluster pool list 2>/dev/null \
        | awk 'NR>1 {print $1,$2,$3}' \
        | grep -E "\s${host}\s" \
        | grep -qE '\bConnected\b'; then
      log_ok "Peer connected: $host (Versuch $i)"
      return 0
    fi
    sleep "$sleep_s"
  done
  log_w "Peer NICHT verbunden: $host"
  return 1
}

volume_exists(){
  local name="$1"
  gluster volume info "$name" >/dev/null 2>&1
}

ensure_volume_started(){
  local name="$1"
  if ! gluster volume info "$name" 2>/dev/null | grep -q "Status: Started"; then
    log_i "Starte Volume: $name"
    gluster volume start "$name" >/dev/null 2>&1 || true
  fi
}

set_volume_options(){
  local name="$1" ; shift
  # erwartet KEY=VALUE Paare
  for kv in "$@"; do
    local k="${kv%%=*}" ; local v="${kv#*=}"
    log_i "Setze Option: $name $k=$v"
    gluster volume set "$name" "$k" "$v" >/dev/null 2>&1 || true
  done
}

# host:path ausgeben; reine Pfade werden zu <REWRITE_LOCAL_BRICKS_TO>:<pfad>
normalize_brick(){
  local spec="$1"
  if [[ "$spec" == *:* ]]; then
    echo "$spec"
  else
    local host="${REWRITE_LOCAL_BRICKS_TO:-$(hostname -s)}"
    echo "${host}:${spec}"
  fi
}

# Lokalen Pfad extrahieren (nur wenn Brick lokal ist), sonst leer
brick_local_path(){
  local spec="$1"
  if [[ "$spec" == *:* ]]; then
    local host="${spec%%:*}"
    local path="${spec#*:}"
    case "$host" in
      127.0.0.1|localhost|$(hostname -s)) echo "$path" ;;
      *) echo "" ;;
    esac
  else
    echo "$spec"
  fi
}

# Directory (bis auf lost+found) leer?
dir_is_effectively_empty(){
  local p="$1"
  [[ -d "$p" ]] || return 2
  shopt -s dotglob nullglob
  local entries=("$p"/*)
  shopt -u dotglob
  local count=0
  for e in "${entries[@]}"; do
    [[ ! -e "$e" ]] && continue
    local b; b="$(basename "$e")"
    [[ "$b" == "lost+found" ]] && continue
    count=$((count+1))
  done
  [[ $count -eq 0 ]]
}

# Preflight: dürfen wir trusted.*-xattr auf dem Brick-Wurzelpfad setzen?
check_brick_xattr(){
  local path="$1"
  if [[ -z "$path" ]]; then return 0; fi  # nicht-lokale Bricks überspringen
  if [[ ! -d "$path" ]]; then
    log_e "Brick-Pfad existiert nicht: $path"
    return 2
  fi
  local key="trusted.glfs.preflight"
  if setfattr -n "$key" -v "1" "$path" 2>/dev/null; then
    getfattr -n "$key" "$path" >/dev/null 2>&1 || true
    setfattr -x "$key" "$path" >/dev/null 2>&1 || true
    return 0
  else
    local err
    err="$(setfattr -n "$key" -v "1" "$path" 2>&1 || true)"
    if echo "$err" | grep -qi "Operation not permitted"; then
      log_e "Kann trusted.* xattr NICHT setzen (EPERM) auf $path."
      log_e "→ Compose/Run ergänzen: cap_add: [\"SYS_ADMIN\"] ODER privileged: true; ggf. security_opt: [\"apparmor:unconfined\"]."
    elif echo "$err" | grep -qi "Operation not supported"; then
      log_e "xattr wird vom Host-FS NICHT unterstützt auf $path."
      log_e "→ Stelle sicher, dass ext4/xfs mit user_xattr,acl gemountet ist."
    else
      log_e "Setzen von xattr auf $path fehlgeschlagen: $err"
    fi
    return 1
  fi
}
