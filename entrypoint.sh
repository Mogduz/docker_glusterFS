#!/usr/bin/env bash
set -Eeuo pipefail
# ---------------------------------------------
# Server identity for brick endpoints (prefer PRIVATE_IP)
# ---------------------------------------------
:
: "${DATA_PORT_END:=}"
# Backward-compat: prefer DATA_PORT_END if provided
if [[ -n "${DATA_PORT_END}" ]]; then MAX_PORT="${DATA_PORT_END}"; fi
ensure_glusterd_vol() {
  : "${DATA_PORT_START:=49152}"
  : "${MAX_PORT:=60999}"
  : "${ADDRESS_FAMILY:=inet}" # inet|inet6
  install -d -m 0755 /etc/glusterfs
  cat > /etc/glusterfs/glusterd.vol <<EOF
volume management
    type mgmt/glusterd
    option working-directory /var/lib/glusterd
    option transport.address-family ${ADDRESS_FAMILY}
    option base-port ${DATA_PORT_START}
    option max-port ${MAX_PORT}
end-volume
EOF
}

pick_server_identity() {
  local cand=""
  if [[ -n "${PRIVATE_IP:-}" && "${PRIVATE_IP}" != 127.* && "${PRIVATE_IP}" != "::1" ]]; then
    cand="${PRIVATE_IP}"
  fi
  [[ -z "$cand" ]] && cand="${HOSTNAME_GLUSTER:-gluster-solo}"
  echo "$cand"
}
export BRICK_HOST="$(pick_server_identity)"



# ---------------------------------------------
# Enforce glusterd.vol with port window & address family
# ---------------------------------------------



ts(){ date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log(){ printf "%s [%s] %s\n" "$(ts)" "$1" "$2"; }
info(){ log INFO "$*"; }
warn(){ log WARN "$*"; }
err(){  log ERROR "$*"; }

: "${VOLNAME:=gv0}"
: "${REPLICA:=2}"
: "${TRANSPORT:=tcp}"
: "${CREATE_VOLUME:=1}"
: "${ALLOW_FORCE_CREATE:=1}"
: "${VOL_OPTS:=performance.client-io-threads=on,cluster.quorum-type=auto}"
: "${AUTH_ALLOW:=10.0.0.0/8}"
: "${NFS_DISABLE:=1}"
: "${BRICK_HOST:=}"
: "${BRICK_PATHS:=}"
: "${DATA_PORT_START:=49152}"
: "${DATA_PORT_END:=60999}"

is_loopback_host() {
  local h="$1"
  [[ -z "$h" ]] && return 0
  [[ "$h" == "localhost" ]] && return 0
  [[ "$h" == "localhost.localdomain" ]] && return 0
  [[ "$h" == "ip6-localhost" ]] && return 0
  if [[ "$h" =~ ^127\. ]] || [[ "$h" =~ ^0\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ "$h" == "::1" ]]; then
    return 0
  fi
  if getent ahostsv4 "$h" >/dev/null 2>&1; then
    local ip
    ip="$(getent ahostsv4 "$h" | awk '{print $1; exit}')"
    [[ "$ip" =~ ^127\. ]] && return 0
    [[ "$ip" =~ ^0\. ]] && return 0
  fi
  return 1
}

pick_primary_ipv4() {
  local ip
  ip="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)"
  if [[ -n "$ip" ]]; then echo "$ip"; return 0; fi
  ip="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | grep -v '^127\.' | head -n1 || true)"
  if [[ -n "$ip" ]]; then echo "$ip"; return 0; fi
  return 1
}

resolve_brick_host() {
  local cand="${BRICK_HOST:-}"
  if is_loopback_host "$cand"; then cand=""; fi
  if [[ -z "$cand" && -n "${PRIVATE_IP:-}" ]]; then
    cand="${PRIVATE_IP}"
    if is_loopback_host "$cand"; then cand=""; fi
  fi
  if [[ -z "$cand" ]]; then
    cand="$(pick_primary_ipv4 || true)"
  fi
  if [[ -z "$cand" ]]; then
    err "Could not determine a non-loopback BRICK_HOST. Set BRICK_HOST=<this-node IPv4/FQDN> in .env."
    return 1
  fi
  if is_loopback_host "$cand"; then
    err "BRICK_HOST resolves to loopback (${cand}). Use a real interface IP or resolvable hostname."
    return 1
  fi
  echo "$cand"
}

if ! getent hosts "$(hostname -s)" >/dev/null 2>&1; then
  echo "127.0.1.1 $(hostname -s)" >> /etc/hosts || true
fi

conf="/etc/glusterfs/glusterd.vol"
if [[ -f "$conf" ]]; then
  if grep -q "option\s\+base-port" "$conf"; then
    sed -ri "s/^\s*option\s+base-port\s+\S+/    option base-port ${DATA_PORT_START}/" "$conf"
  else
    sed -ri '/^volume management$/,/^end-volume$/ s/^end-volume$/    option base-port '"$DATA_PORT_START"'\n&/' "$conf"
  fi
  if grep -q "option\s\+max-port" "$conf"; then
    sed -ri "s/^\s*option\s+max-port\s+\S+/    option max-port ${MAX_PORT}/" "$conf"
  else
    sed -ri '/^volume management$/,/^end-volume$/ s/^end-volume$/    option max-port '"$DATA_PORT_END"'\n&/' "$conf"
  fi
else
  cat >"$conf" <<EOF
volume management
    type mgmt/glusterd
    option working-directory /var/lib/glusterd
    option transport.socket.listen-port 24007
    option base-port ${DATA_PORT_START}
    option max-port ${MAX_PORT}
end-volume
EOF
fi

mkdir -p /var/lib/glusterd /var/log/glusterfs

info "starting glusterd (foreground, -N)"
/usr/sbin/glusterd -N &
GLUSTERD_PID=$!

wait_glusterd(){
  local t=${1:-120}
  for ((i=0;i<t;i++)); do
    if gluster --mode=script volume list >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  err "glusterd did not become ready within ${t}s"; return 1
}

get_bricks(){
  if [[ -n "$BRICK_PATHS" ]]; then
    IFS=',' read -r -a arr <<< "$BRICK_PATHS"
    printf '%s\n' "${arr[@]}"
    return
  fi
  ls -d /bricks/brick* 2>/dev/null | sort -V || true
}

maybe_create_volume(){
  [[ "$CREATE_VOLUME" == "1" ]] || { info "CREATE_VOLUME=0 -> skip"; return 0; }

  if gluster --mode=script volume info "$VOLNAME" >/dev/null 2>&1; then
    info "volume $VOLNAME already exists"; return 0
  fi

  mapfile -t bricks < <(get_bricks)
  if [[ ${#bricks[@]} -eq 0 ]]; then
    err "no bricks found under /bricks; set HOST_BRICK* in .env"; return 1
  fi

  if [[ "$REPLICA" -ge 2 ]]; then
    if (( ${#bricks[@]} % REPLICA != 0 )); then
      err "brick count ${#bricks[@]} not a multiple of REPLICA=$REPLICA"; return 1
    fi
  fi

  for b in "${bricks[@]}"; do mkdir -p "$b"; done

  local host
  host="$(resolve_brick_host)" || return 1
  info "using BRICK_HOST=${host}"

  specs=()
  for b in "${bricks[@]}"; do
    specs+=("${host}:${b}")
  done

  args=(volume create "$VOLNAME")
  if [[ "$REPLICA" -ge 2 ]]; then args+=(replica "$REPLICA"); fi
  args+=(transport "$TRANSPORT")
  args+=("${specs[@]}")
  [[ "$ALLOW_FORCE_CREATE" == "1" ]] && args+=(force)

  info "creating: gluster ${args[*]}"
  if ! gluster "${args[@]}"; then
    err "volume create failed"; return 1
  fi

  if [[ -n "$VOL_OPTS" ]]; then
    IFS=',' read -ra kvs <<< "$VOL_OPTS"
    for kv in "${kvs[@]}"; do
      [[ -n "$kv" ]] || continue
      info "set ${kv}"
      gluster volume set "$VOLNAME" "$kv" || true
    done
  fi

  if [[ -n "$AUTH_ALLOW" ]]; then
    info "set auth.allow=${AUTH_ALLOW}"
    gluster volume set "$VOLNAME" auth.allow "$AUTH_ALLOW" || true
  fi

  [[ "$NFS_DISABLE" == "1" ]] && gluster volume set "$VOLNAME" nfs.disable on || true
  info "starting volume $VOLNAME"
  gluster volume start "$VOLNAME" || true
}

(
  wait_glusterd || exit 1
  maybe_create_volume || true
) &

trap 'kill ${GLUSTERD_PID} 2>/dev/null || true' EXIT
wait ${GLUSTERD_PID}