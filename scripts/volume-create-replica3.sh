#!/usr/bin/env bash
# Usage: ./scripts/volume-create-replica3.sh <VOL> <HOST1> <HOST2> <HOST3> [BRICK_PATH=/bricks/brick1]
set -euo pipefail
VOL="${1:?vol}"; H1="${2:?host1}"; H2="${3:?host2}"; H3="${4:?host3}"; BP="${5:-/bricks/brick1}"
set -x
gluster volume create "$VOL" replica 3 "$H1":"$BP" "$H2":"$BP" "$H3":"$BP" force
gluster volume start "$VOL"
set +x
gluster volume info "$VOL"
