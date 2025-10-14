#!/usr/bin/env bash
# Usage: ./scripts/volume-create-replica2.sh <VOL> <HOST1> <HOST2> [BRICK_PATH=/bricks/brick1]
set -euo pipefail
VOL="${1:?vol}"; H1="${2:?host1}"; H2="${3:?host2}"; BP="${4:-/bricks/brick1}"
set -x
gluster volume create "$VOL" replica 2 "$H1":"$BP" "$H2":"$BP" force
gluster volume start "$VOL"
set +x
gluster volume info "$VOL"
