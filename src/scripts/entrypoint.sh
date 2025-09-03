#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "[ERROR] Abbruch (Exit-Code $?) an Zeile $LINENO" >&2' ERR

# libs
source /opt/gluster-scripts/lib/log.sh
source /opt/gluster-scripts/lib/common.sh
banner

# env summary
log "Node-Name            : ${NODE}"
log "Persistenz-Root      : ${ROOT}"
log "YAML-Konfig          : ${CONFIG}"
log "Peers auto-probe     : ${AUTO_PROBE}"
log "Volumes auto-manage  : ${AUTO_CREATE}"
log "Manager-Node         : ${MANAGER_NODE:-<nicht gesetzt>}"
log "Fail bei ungemount.  : ${FAIL_ON_UNMOUNTED_BRICK}"
log "Single-Brick erlaubt : ${ALLOW_SINGLE_BRICK}"
log "Wait(tries/sleep)    : ${GLUSTER_WAIT_TRIES}/${GLUSTER_WAIT_SLEEP}s"
log "Rewrite local bricks : ${REWRITE_LOCAL_BRICKS} → ${LOCAL_BRICK_HOST}"
[ -n "${BRICKS_ENV}" ] && log "BRICKS (ENV)         : ${BRICKS_ENV}"

# steps
source /opt/gluster-scripts/steps/10-preflight.sh
source /opt/gluster-scripts/steps/20-bricks.sh
source /opt/gluster-scripts/steps/30-glusterd.sh
source /opt/gluster-scripts/steps/40-peers.sh
source /opt/gluster-scripts/steps/50-volumes.sh

step_preflight
step_bricks
step_glusterd
step_peers
step_volumes

step "Läuft. Übergabe an glusterd – Logs unter $ROOT/logs/"
wait "$GLUSTERD_PID"
