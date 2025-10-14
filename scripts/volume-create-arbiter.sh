#!/usr/bin/env bash
# Usage: ./scripts/volume-create-arbiter.sh <VOL> <DATA1> <DATA2> <ARBITER> [BRICK_PATH=/bricks/brick1]
# DATA1/DATA2 are the two data-hosts, ARBITER is the arbiter host (replica 3 arbiter 1)
set -euo pipefail
VOL="${1:?vol}"; D1="${2:?data1}"; D2="${3:?data2}"; A="${4:?arbiter}"; BP="${5:-/bricks/brick1}"
set -x
gluster volume create "$VOL" replica 3 arbiter 1 "$D1":"$BP" "$D2":"$BP" "$A":"$BP" force
gluster volume start "$VOL"
set +x
gluster volume info "$VOL"
