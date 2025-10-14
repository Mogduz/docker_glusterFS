#!/usr/bin/env bash
# Minimal, robust GlusterFS bootstrap for container use (no systemd).
# Starts glusterd in foreground and, if configured, creates/starts a solo volume.
set -Eeuo pipefail

ts(){ date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log(){ printf "%s [%s] %s\n" "$(ts)" "$1" "$2"; }
info(){ log INFO "$*"; }
warn(){ log WARN "$*"; }
err(){  log ERROR "$*"; }

# --- defaults ---
: "${VOLNAME:=gv0}"
: "${REPLICA:=2}"
: "${TRANSPORT:=tcp}"
: "${CREATE_VOLUME:=1}"
: "${ALLOW_FORCE_CREATE:=1}"
: "${VOL_OPTS:=performance.client-io-threads=on,cluster.quorum-type=auto}"
: "${AUTH_ALLOW:=10.0.0.0/8}"
: "${NFS_DISABLE:=1}"
# BRICK_HOST decides what goes in 'HOST:/path' for bricks.
# Default to 'localhost' to avoid Peer-in-Cluster hostname mismatches in single-node setups.
: "${BRICK_HOST:=localhost}"

# Ensure hostname is resolvable (helps glusterd choose a stable name)
# Add 127.0.1.1 mapping if missing
if ! getent hosts "$(hostname -s)" >/dev/null 2>&1; then
  echo "127.0.1.1 $(hostname -s)" >> /etc/hosts || true
fi

# Prepare directories expected by glusterd and our bricks
mkdir -p /var/lib/glusterd /var/log/glusterfs /bricks/brick1 /bricks/brick2

# Start glusterd in the foreground (no daemon)
info "starting glusterd (foreground, -N)"
/usr/sbin/glusterd -N &
GLUSTERD_PID=$!

# Helper to wait until CLI can talk to glusterd
wait_glusterd() {
  local waited=0
  local timeout="${1:-90}"
  until gluster --mode=script volume list >/dev/null 2>&1; do
    sleep 1; waited=$((waited+1))
    if (( waited >= timeout )); then
      err "glusterd did not become ready within ${timeout}s"
      kill ${GLUSTERD_PID} || true
      exit 1
    fi
  done
}

# Create a solo replica-2 volume on two bricks on the same node (force if allowed)
maybe_create_volume() {
  if [[ "${CREATE_VOLUME}" != "1" ]]; then
    info "CREATE_VOLUME=0 -> skipping volume creation"
    return 0
  fi

  if gluster --mode=script volume info "${VOLNAME}" >/dev/null 2>&1; then
    info "volume ${VOLNAME} already exists"
    return 0
  fi

  local bricks="${BRICK_HOST}:/bricks/brick1 ${BRICK_HOST}:/bricks/brick2"
  local force_flag=""
  if [[ "${ALLOW_FORCE_CREATE}" == "1" ]]; then
    force_flag="force"
  fi

  info "creating volume ${VOLNAME} replica ${REPLICA} transport ${TRANSPORT} on ${bricks} ${force_flag}"
  if ! gluster volume create "${VOLNAME}" replica "${REPLICA}" transport "${TRANSPORT}" ${bricks} ${force_flag}; then
    err "failed to create volume (see /var/log/glusterfs/glusterd.log and cli.log)"
    return 1
  fi

  if [[ -n "${VOL_OPTS}" ]]; then
    IFS=',' read -ra pairs <<< "${VOL_OPTS}"
    for kv in "${pairs[@]}"; do
      if [[ -n "${kv}" ]]; then
        info "setting volume option ${kv}"
        gluster volume set "${VOLNAME}" "${kv}" || true
      fi
    done
  fi

  if [[ -n "${AUTH_ALLOW}" ]]; then
    info "setting auth.allow=${AUTH_ALLOW}"
    gluster volume set "${VOLNAME}" auth.allow "${AUTH_ALLOW}" || true
  fi

  if [[ "${NFS_DISABLE}" == "1" ]]; then
    info "disabling legacy NFS translator"
    gluster volume set "${VOLNAME}" nfs.disable on || true
  fi

  info "starting volume ${VOLNAME}"
  gluster volume start "${VOLNAME}" || true
}

# Background init that waits for glusterd and (maybe) creates volume
(
  wait_glusterd 120 || exit 1
  maybe_create_volume || true
) &

# Keep container running as long as glusterd runs
trap 'kill ${GLUSTERD_PID} 2>/dev/null || true' EXIT
wait ${GLUSTERD_PID}
