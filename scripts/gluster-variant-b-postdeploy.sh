\
#!/usr/bin/env bash
set -euo pipefail
VOLUME="${VOLUME:-gv0}"
CIDR="${PRIVATE_CIDR:-10.0.0.0/24}"
echo "[INFO] Setting auth.allow=${CIDR} on ${VOLUME}"
docker exec -i gluster-solo gluster volume set "${VOLUME}" auth.allow "${CIDR}"
docker exec -i gluster-solo gluster volume get "${VOLUME}" auth.allow
