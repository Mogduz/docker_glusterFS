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

# Seed default config into /gluster/etc on first run (glusterd requires glusterd.vol at least)
if [[ ! -s /etc/glusterfs/glusterd.vol ]]; then
  log_w "Keine glusterd.vol gefunden – seed Defaults nach /etc/glusterfs (persistiert nach /gluster/etc)"
  cp -a /opt/glusterfs-defaults/. /etc/glusterfs/
fi

# Ensure runtime dir for pid/socket exists
mkdir -p /run/gluster /var/run/gluster

# Starte glusterd (Management-Daemon)
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

# ---------------- Auto-Management: Peers & Volumes ----------------

REWRITE_LOCAL_BRICKS_TO="${REWRITE_LOCAL_BRICKS_TO:-127.0.0.1}"

if [[ "${AUTO_PROBE_PEERS}" == "true" ]]; then
  section "Auto-Probe Peers (YAML/ENV)"
  # Collect peers: YAML first, then ENV PEERS (space/comma-separated)
  peers=()
  while IFS= read -r p; do [[ -n "$p" ]] && peers+=("$p"); done < <(yaml_get_peers "${GLUSTER_CONFIG}" || true)
  if [[ -n "${PEERS:-}" ]]; then
    IFS=', ' read -r -a env_peers <<< "${PEERS}"
    peers+=("${env_peers[@]}")
  fi
  # De-duplicate
  tmp=(); declare -A seen=()
  for x in "${peers[@]}"; do [[ -z "${seen[$x]:-}" ]] && tmp+=("$x") && seen[$x]=1; done
  peers=("${tmp[@]}")

  for peer in "${peers[@]}"; do
    [[ "$peer" == "$(hostname -s)" || "$peer" == "127.0.0.1" || "$peer" == "localhost" ]] && continue
    gluster_peer_probe "$peer"
    wait_peer_connected "$peer" 60 1 || true
  done
fi

if [[ "${AUTO_CREATE_VOLUMES}" == "true" ]]; then
  section "Auto-Manage Volumes (YAML/ENV)"
  vol_names=()
  while IFS= read -r v; do [[ -n "$v" ]] && vol_names+=("$v"); done < <(yaml_get_vol_names "${GLUSTER_CONFIG}" || true)

  if [[ "${#vol_names[@]}" -eq 0 ]]; then
    # Legacy single volume from bricks list
    legacy_bricks=()
    while IFS= read -r b; do [[ -n "$b" ]] && legacy_bricks+=("$b"); done < <(yaml_get_bricks_legacy "${GLUSTER_CONFIG}" || true)
    if [[ -z "${BRICKS:-}" && "${#legacy_bricks[@]}" -eq 0 ]]; then
      log_w "Keine Volumes und keine Bricks in YAML/ENV gefunden – überspringe Auto-Create."
    else
      VOL_NAME="${VOL_NAME:-gv0}"
      bricks=()
      if [[ -n "${BRICKS:-}" ]]; then
        IFS=', ' read -r -a env_bricks <<< "${BRICKS}"
        bricks=("${env_bricks[@]}")
      else
        bricks=("${legacy_bricks[@]}")
      fi
      # normalize bricks to host:path
      nbricks=()
      for b in "${bricks[@]}"; do
        nb="$(normalize_brick "$b")"
        nbricks+=("$nb")
      done
      if ! volume_exists "$VOL_NAME"; then
        if [[ "${ALLOW_SINGLE_BRICK}" != "true" && "${#nbricks[@]}" -lt 2 ]]; then
          log_e "Zu wenige Bricks (${#nbricks[@]}) für Volume $VOL_NAME und ALLOW_SINGLE_BRICK=false"
          exit 96
        fi
        log_i "Erzeuge Volume: $VOL_NAME (${#nbricks[@]} Bricks)"
        gluster volume create "$VOL_NAME" "${nbricks[@]}" force >/dev/null 2>&1 || true
      fi
      ensure_volume_started "$VOL_NAME"
    fi
  else
    # Full YAML volumes
    for V in "${vol_names[@]}"; do
      vtype="$(yaml_get_vol_field "${GLUSTER_CONFIG}" "$V" type)"
      replica="$(yaml_get_vol_field "${GLUSTER_CONFIG}" "$V" replica)"
      dist="$(yaml_get_vol_field "${GLUSTER_CONFIG}" "$V" disperse)"
      arbiter="$(yaml_get_vol_field "${GLUSTER_CONFIG}" "$V" arbiter)"
      # bricks
      bricks=()
      while IFS= read -r b; do [[ -n "$b" ]] && bricks+=("$b"); done < <(yaml_get_vol_bricks "${GLUSTER_CONFIG}" "$V" || true)
      if [[ "${#bricks[@]}" -eq 0 && -n "${BRICKS:-}" ]]; then
        IFS=', ' read -r -a env_bricks <<< "${BRICKS}"
        bricks=("${env_bricks[@]}")
      fi
      nbricks=()
      for b in "${bricks[@]}"; do
        nb="$(normalize_brick "$b")"
        nbricks+=("$nb")
      done
      if ! volume_exists "$V"; then
        build=(volume create "$V")
        # layout flags
        case "${vtype}" in
          replicate|replica)
            if [[ -n "$replica" ]]; then build+=(replica "$replica"); fi ;;
          disperse|erasure|ec)
            if [[ -n "$dist" ]]; then build+=(disperse-data "$dist"); fi ;;
          arbiter)
            if [[ -n "$replica" ]]; then build+=(replica "$replica" arbiter "${arbiter:-1}"); fi ;;
          *)
            : # distributed (default)
            ;;
        esac
        build+=("${nbricks[@]}")
        build+=(force)
        log_i "Erzeuge Volume $V: ${build[*]}"
        gluster "${build[@]}" >/dev/null 2>&1 || true
      fi
      ensure_volume_started "$V"

      # options
      if command -v yq >/dev/null 2>&1; then
        mapfile -t kvs < <(yq -r "( .cluster.volumes // .volumes // [] )
          | map(select(.name == \"$V\")) | .[0].options | to_entries[]? | \"\(.key)=\(.value)\"" "${GLUSTER_CONFIG}" 2>/dev/null || true)
        if [[ "${#kvs[@]}" -gt 0 ]]; then
          set_volume_options "$V" "${kvs[@]}"
        fi
      fi
    done
  fi
fi

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
