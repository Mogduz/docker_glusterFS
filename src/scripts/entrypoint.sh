#!/usr/bin/env bash
set -Eeuo pipefail

source /opt/gluster-scripts/lib/common.sh

GLUSTER_ROOT="${GLUSTER_ROOT:-/gluster}"
GLUSTER_CONFIG="${GLUSTER_CONFIG:-/gluster/etc/cluster.yml}"
AUTO_PROBE_PEERS="${AUTO_PROBE_PEERS:-true}"
AUTO_CREATE_VOLUMES="${AUTO_CREATE_VOLUMES:-false}"
FAIL_ON_UNMOUNTED_BRICK="${FAIL_ON_UNMOUNTED_BRICK:-true}"
ALLOW_SINGLE_BRICK="${ALLOW_SINGLE_BRICK:-false}"
WAIT_TRIES="${WAIT_TRIES:-120}"
WAIT_SLEEP="${WAIT_SLEEP:-1}"

echo "  GlusterFS Container Entrypoint"
echo
log_i "Node-Name            : $(hostname -s)"
log_i "Persistenz-Root      : ${GLUSTER_ROOT}"
log_i "YAML-Konfig          : ${GLUSTER_CONFIG}"
log_i "Peers auto-probe     : ${AUTO_PROBE_PEERS}"
log_i "Volumes auto-manage  : ${AUTO_CREATE_VOLUMES}"
log_i "Fail bei ungemount.  : ${FAIL_ON_UNMOUNTED_BRICK}"
log_i "Single-Brick erlaubt : ${ALLOW_SINGLE_BRICK}"
log_i "Wait(tries/sleep)    : ${WAIT_TRIES}/${WAIT_SLEEP}s"

section "Verzeichnisstruktur & Basismount prüfen"
if is_mounted "${GLUSTER_ROOT}"; then
  log_ok "Persistenz-Mount erkannt: ${GLUSTER_ROOT}"
else
  log_w "Persistenz-Verzeichnis nicht beschreibbar: ${GLUSTER_ROOT}"
fi

# Ensure directories exist
require_dir "${GLUSTER_ROOT}/etc"
require_dir "${GLUSTER_ROOT}/glusterd"
require_dir "${GLUSTER_ROOT}/logs"
require_dir "${GLUSTER_ROOT}/bricks"

# Starte glusterd (daemonisiert standardmäßig)
section "Starte glusterd (Management-Daemon)"
glusterd
sleep 0.5
if pgrep -x glusterd >/dev/null; then
  log_ok "glusterd PID: $(pgrep -x glusterd | head -n1)"
else
  log_e "Konnte glusterd nicht starten."
  exit 97
fi

# ---- FIX: Korrektes Readiness-Warten (NICHT glusterd im Loop aufrufen) ----
if ! wait_for_glusterd "${WAIT_TRIES}" "${WAIT_SLEEP}"; then
  exit 98
fi

# Optional: Auto-Probe / Volumes hier (aus Fokus gelassen, um den Start zu entblocken)

# Im Vordergrund bleiben: Log folgen (falls vorhanden)
if [[ -f /var/log/glusterfs/glusterd.log ]]; then
  tail -F /var/log/glusterfs/glusterd.log &
  TAIL_PID=$!
  trap 'kill -TERM ${TAIL_PID} || true' EXIT
fi

# Warten; Healthcheck beendet den Container, wenn glusterd stirbt
while sleep 60; do
  if ! pgrep -x glusterd >/dev/null; then
    log_e "glusterd Prozess beendet."
    exit 99
  fi
done
