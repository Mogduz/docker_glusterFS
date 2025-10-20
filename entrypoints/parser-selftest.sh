#!/bin/sh
set -eu

file="${1:-examples/volume/volumes.yml.example}"
# fallback minimal YAML if missing
if [ ! -s "$file" ]; then
  file="$(mktemp)"
  cat >"$file" <<'YAML'
volumes:
  - name: gv0
    replica: 1
    transport: tcp
    bricks:
      - /bricks/gv0/brick1
    options:
      performance.cache-size: 64MB
    options_reset:
      - cluster.min-free-disk
    quota:
      limit: 5GB
      soft_limit_pct: 80
YAML
fi

# Try running emit_yaml_specs from entrypoint.sh with yq
EP="/usr/local/bin/entrypoint.sh"
[ -x "$EP" ] || EP="entrypoints/entrypoint.sh"

if command -v yq >/dev/null 2>&1; then
  # shellcheck disable=SC1090
  . "$EP"
  echo "SELFTEST: using yq-backed emit_yaml_specs"
  out="$(emit_yaml_specs "$file" || true)"
else
  echo "SELFTEST: yq not found, using Python fallback"
  out="$(python3 - "$file" <<'PY'
import sys, json
import yaml
p = sys.argv[1]
data = yaml.safe_load(open(p))
for v in data.get("volumes", []):
    print("__BEGIN_VOL__")
    print(f"VOLNAME={v.get('name','')}")
    if 'replica' in v: print(f"REPLICA={v['replica']}")
    if 'transport' in v: print(f"TRANSPORT={v['transport']}")
    if 'auth_allow' in v: print(f"AUTH_ALLOW={v['auth_allow']}")
    if 'nfs_disable' in v: print(f"NFS_DISABLE={str(v['nfs_disable']).lower()}")
    opts = v.get('options') or {}
    for k,val in opts.items():
        print(f"VOL_OPT {k}={val}")
    orst = v.get('options_reset')
    if orst:
        if isinstance(orst, list): print("OPTIONS_RESET=" + " ".join(map(str, orst)))
        else: print(f"OPTIONS_RESET={orst}")
    quota = v.get('quota') or {}
    if 'limit' in quota: print(f"YAML_QUOTA_LIMIT={quota['limit']}")
    if 'soft_limit_pct' in quota: print(f"YAML_QUOTA_SOFT={quota['soft_limit_pct']}")
    print("__END_VOL__")
PY
)"
fi

echo "$out" | sed -n '1,40p'

# Sanity checks
echo "$out" | grep -q "__BEGIN_VOL__" || { echo "SELFTEST: missing __BEGIN_VOL__" >&2; exit 3; }
echo "$out" | grep -q "__END_VOL__"   || { echo "SELFTEST: missing __END_VOL__" >&2; exit 3; }
echo "$out" | grep -q "^VOLNAME="     || { echo "SELFTEST: missing VOLNAME=" >&2; exit 3; }

echo "SELFTEST: OK"
