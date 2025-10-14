#!/usr/bin/env bash
# Usage: ./scripts/peer-probe.sh host2 [host3 ...]
set -euo pipefail
for h in "$@"; do
  echo "gluster peer probe $h"
  gluster peer probe "$h" || true
done
gluster peer status
