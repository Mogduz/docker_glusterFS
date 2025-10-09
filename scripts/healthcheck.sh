#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# GlusterFS container healthcheck
# - If ROLE resolves to "client" (from $ROLE env or CONFIG_PATH), ensure the configured
#   mount target is currently mounted (i.e., the FUSE mount is active).
# - Otherwise, assume server mode and ensure `glusterd` is running and the CLI responds.
# The script is intentionally strict (`set -euo pipefail`) and exits 0 on success.
# -----------------------------------------------------------------------------
set -euo pipefail
# Role can be forced via env; otherwise derived from config file
ROLE="${ROLE:-}"
CFG_PATH="${CONFIG_PATH:-/etc/gluster-container/config.yaml}"
# Auto-detect role from YAML config when not provided
if [[ -z "$ROLE" && -f "$CFG_PATH" ]]; then
  ROLE="$(python3 - <<'PY'
import yaml,sys,os
p=os.environ.get('CONFIG_PATH','/etc/gluster-container/config.yaml')
cfg={}
try:
  with open(p) as f: cfg=yaml.safe_load(f) or {}
except Exception: pass
print((cfg.get('role') or 'server').lower())
PY
)"
fi

if [[ "$ROLE" == "client" ]]; then
  # Expect first target to be mounted
  TARGET="$(python3 - <<'PY'
import yaml,os
p=os.environ.get('CONFIG_PATH','/etc/gluster-container/config.yaml')
cfg={}
try:
  with open(p) as f: cfg=yaml.safe_load(f) or {}
except Exception: pass
ms=cfg.get('mounts') or []
print(ms[0]['target'] if ms else '/mnt/glusterFS')
PY
)"
  # In client mode: validate that the target path is a mountpoint
  mountpoint -q "$TARGET"
  exit 0
else
  # Server: check glusterd process + CLI
  # In server mode: check that glusterd is running
  pgrep -x glusterd >/dev/null 2>&1
  gluster volume list >/dev/null 2>&1 || gluster peer status >/dev/null 2>&1
  exit 0
fi
