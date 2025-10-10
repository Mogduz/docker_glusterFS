#!/usr/bin/env bash
# GlusterFS container healthcheck (robust & bash-only interface to python)
set -Eeuo pipefail

log() { printf '%s [%s] %s\n' "$(date -u +'%FT%TZ')" "$1" "$2" >&2; }
die() { log "ERROR" "$1"; exit "${2:-1}"; }

CFG_PATH="${CONFIG_PATH:-/etc/gluster-container/config.yaml}"
ROLE="${ROLE:-}"

# Rolle ggf. aus YAML lesen (fallback: server)
if [[ -z "${ROLE}" && -f "${CFG_PATH}" ]]; then
  ROLE="$(python3 - <<'PY' 2>/dev/null || true
import os, sys
try:
    import yaml
except Exception:
    print("server"); sys.exit(0)
p = os.environ.get("CONFIG_PATH", "/etc/gluster-container/config.yaml")
try:
    with open(p, "r", encoding="utf-8") as f:
        cfg = yaml.safe_load(f) or {}
    role = (cfg.get("role") or "server").strip().lower()
    print(role or "server")
except Exception:
    print("server")
PY
)"
fi

ROLE="${ROLE:-server}"

if [[ "${ROLE}" == "client" ]]; then
  # Aus YAML Mount-Ziele lesen (optional)
  readarray -t TARGETS < <(python3 - <<'PY' 2>/dev/null || true
import os, sys
try:
    import yaml
except Exception:
    sys.exit(0)
p = os.environ.get("CONFIG_PATH", "/etc/gluster-container/config.yaml")
try:
    with open(p, "r", encoding="utf-8") as f:
        cfg = yaml.safe_load(f) or {}
    mounts = (((cfg.get("client") or {}).get("mounts")) or [])
    for m in mounts:
        t = (m.get("target") or m.get("mountpoint") or "").strip()
        if t:
            print(t)
except Exception:
    pass
PY
)
  if ((${#TARGETS[@]})); then
    for t in "${TARGETS[@]}"; do
      mountpoint -q -- "$t" || die "Mountpunkt nicht aktiv: $t" 2
    done
    log "INFO" "Client-Mounts OK"
    exit 0
  fi
  # Fallback: glusterfs (FUSE) Prozess vorhanden?
  if pgrep -x glusterfs >/dev/null 2>&1; then
    log "INFO" "glusterfs (FUSE) Prozess OK"
    exit 0
  fi
  die "Keine Client-Mounts und kein glusterfs-Prozess gefunden" 3
else
  # Server-Checks
  if ! pgrep -x glusterd >/dev/null 2>&1; then
    die "glusterd Prozess nicht gefunden" 4
  fi
  if gluster volume list >/dev/null 2>&1 || gluster peer status >/dev/null 2>&1; then
    log "INFO" "glusterd/CLI OK"
    exit 0
  fi
  die "gluster CLI antwortet nicht" 5
fi
