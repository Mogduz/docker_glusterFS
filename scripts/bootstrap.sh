#!/usr/bin/env bash
set -euo pipefail
MOUNT_ROOT="${MOUNT_ROOT:-/mnt/data}"
# Create minimal tree if missing/empty
if [ ! -d "$MOUNT_ROOT" ] || [ -z "$(ls -A "$MOUNT_ROOT" 2>/dev/null || true)" ]; then
  echo "[BOOTSTRAP] initialize central tree under $MOUNT_ROOT"
  mkdir -p "$MOUNT_ROOT/etc/glusterfs"                "$MOUNT_ROOT/etc/gluster-container"                "$MOUNT_ROOT/var/lib/glusterd"                "$MOUNT_ROOT/log/glusterfs"                "$MOUNT_ROOT/bricks/brick1/gv0"
  # default config
  if [ ! -f "$MOUNT_ROOT/etc/gluster-container/config.yaml" ]; then
    printf "role: server\n" > "$MOUNT_ROOT/etc/gluster-container/config.yaml"
  fi
else
  echo "[BOOTSTRAP] central tree exists; skipping initialization"
fi

# Idempotent helper: create symlink, backing up real paths once
ensure_link() {
  local src="$1" dst="$2"
  mkdir -p "$(dirname "$dst")" "$(dirname "$src")"
  if [ -L "$dst" ]; then
    local cur; cur="$(readlink "$dst" || true)"
    if [ "$cur" = "$src" ]; then return 0; fi
    rm -f "$dst"
  elif [ -e "$dst" ]; then
    local ts; ts="$(date +%Y%m%d-%H%M%S)"
    mv "$dst" "${dst}.bak-${ts}"
    echo "[BOOTSTRAP] moved $dst -> ${dst}.bak-${ts}"
  fi
  ln -s "$src" "$dst"
}

ensure_link "$MOUNT_ROOT/etc/glusterfs"        "/etc/glusterfs"
ensure_link "$MOUNT_ROOT/etc/gluster-container" "/etc/gluster-container"
ensure_link "$MOUNT_ROOT/var/lib/glusterd"     "/var/lib/glusterd"
ensure_link "$MOUNT_ROOT/log/glusterfs"        "/var/log/glusterfs"
ensure_link "$MOUNT_ROOT/bricks/brick1"        "/bricks/brick1"

# Optional xattr self-test (non-fatal)
PROBE="$MOUNT_ROOT/bricks/brick1/gv0/.xattr_probe"
touch "$PROBE" || true
if command -v setfattr >/dev/null 2>&1 && command -v getfattr >/dev/null 2>&1; then
  setfattr -n user.test -v 1 "$PROBE" || echo "[BOOTSTRAP] WARN: user.* xattr failed"
  setfattr -n trusted.glusterfs.probe -v 1 "$PROBE" || echo "[BOOTSTRAP] WARN: trusted.* xattr failed"
  rm -f "$PROBE" || true
else
  echo "[BOOTSTRAP] INFO: xattr tools not present; skipping smoke test"
fi

echo "[BOOTSTRAP] done; exec entrypoint -> $*"
exec /usr/local/bin/entrypoint.py "$@"
