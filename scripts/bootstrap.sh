#!/usr/bin/env bash
set -euo pipefail
MOUNT_ROOT="${MOUNT_ROOT:-/mnt/data}"

log(){ echo "[BOOTSTRAP] $*"; }

init_tree() {
  if [ ! -d "$MOUNT_ROOT" ] || [ -z "$(ls -A "$MOUNT_ROOT" 2>/dev/null || true)" ]; then
    log "initialize central tree under $MOUNT_ROOT"
    mkdir -p "$MOUNT_ROOT/etc/glusterfs"                  "$MOUNT_ROOT/etc/gluster-container"                  "$MOUNT_ROOT/var/lib/glusterd"                  "$MOUNT_ROOT/log/glusterfs"                  "$MOUNT_ROOT/bricks/brick1/gv0"
    if [ ! -f "$MOUNT_ROOT/etc/gluster-container/config.yaml" ]; then
      printf "role: server\n" > "$MOUNT_ROOT/etc/gluster-container/config.yaml"
    fi
  else
    log "central tree exists; skipping initialization"
  fi
}

# Try to replace a system path with a symlink to central. If that fails with EBUSY,
# fall back to a bind-mount (requires CAP_SYS_ADMIN).
ensure_overlay() {
  local src="$1" dst="$2"
  mkdir -p "$(dirname "$dst")" "$(dirname "$src")"

  # already a symlink to the right place?
  if [ -L "$dst" ] && [ "$(readlink "$dst" || true)" = "$src" ]; then
    return 0
  fi

  # try to create a symlink by moving the old path aside
  if [ -e "$dst" ] && [ ! -L "$dst" ]; then
    local ts; ts="$(date +%Y%m%d-%H%M%S)"
    if mv "$dst" "${dst}.bak-${ts}" 2>/tmp/mv.err; then
      log "moved $dst -> ${dst}.bak-${ts}"
    else
      # mv failed (likely EBUSY). Try bind-mount instead.
      log "mv failed for $dst (likely busy). Attempting bind-mount overlay."
      if mount --bind "$src" "$dst" 2>/tmp/bind.err; then
        log "bind-mounted $src -> $dst"
        return 0
      else
        log "bind-mount failed: $(cat /tmp/bind.err || true)"
        # As last resort, sync contents so both trees match and keep original path
        rsync -a --delete "$dst"/ "$src"/ 2>/tmp/rsync.err || true
        log "synced contents from $dst to $src; keeping original path (no symlink)."
        return 0
      fi
    fi
  fi

  ln -sfn "$src" "$dst"
}

init_tree

ensure_overlay "$MOUNT_ROOT/etc/glusterfs"        "/etc/glusterfs"
ensure_overlay "$MOUNT_ROOT/etc/gluster-container" "/etc/gluster-container"
ensure_overlay "$MOUNT_ROOT/var/lib/glusterd"     "/var/lib/glusterd"
ensure_overlay "$MOUNT_ROOT/log/glusterfs"        "/var/log/glusterfs"
ensure_overlay "$MOUNT_ROOT/bricks/brick1"        "/bricks/brick1"

# Optional xattr smoke-test (non-fatal)
PROBE="$MOUNT_ROOT/bricks/brick1/gv0/.xattr_probe"
touch "$PROBE" 2>/dev/null || true
if command -v setfattr >/dev/null 2>&1 && command -v getfattr >/dev/null 2>&1; then
  setfattr -n user.test -v 1 "$PROBE" || log "WARN: user.* xattr failed"
  setfattr -n trusted.glusterfs.probe -v 1 "$PROBE" || log "WARN: trusted.* xattr failed"
  rm -f "$PROBE" || true
else
  log "INFO: xattr tools not present; skipping smoke test"
fi

log "done; exec entrypoint -> $*"
exec /usr/local/bin/entrypoint.py "$@"
