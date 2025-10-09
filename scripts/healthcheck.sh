#!/usr/bin/env bash
set -euo pipefail
ROLE="${ROLE:-}"
CFG_PATH="${CONFIG_PATH:-/etc/gluster-container/config.yaml}"
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
  mountpoint -q "$TARGET"
  exit 0
else
  # Server: check glusterd process + CLI
  pgrep -x glusterd >/dev/null 2>&1
  gluster volume list >/dev/null 2>&1 || gluster peer status >/dev/null 2>&1
  exit 0
fi
