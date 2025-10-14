#!/usr/bin/env bash
# shellcheck shell=bash
set -Eeuo pipefail
trap 'rc=$?; [[ $rc -eq 0 ]] && exit 0; echo "$(date -u +%FT%TZ) [ERROR] rc=$rc at ${BASH_SOURCE[0]}:${LINENO} :: ${BASH_COMMAND}" >&2' ERR

# ----- tiny logger -----
ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log(){ printf "%s [%s] %s\n" "$(ts)" "$1" "$2"; }
info(){ log INFO "$*"; }
warn(){ log WARN "$*"; }
err(){  log ERROR "$*"; }
ok(){   log OK "$*"; }
banner(){ printf "\n%s [PHASE] %s\n\n" "$(ts)" "$*"; }

# ----- config -----
: "${VOLNAME:=gv0}"
: "${VTYPE:=replica}"
: "${REPLICA:=2}"
: "${TRANSPORT:=tcp}"
: "${MODE:=init}"
: "${CREATE_VOLUME:=1}"
: "${ALLOW_FORCE_CREATE:=1}"
: "${VOL_OPTS:=}"
: "${AUTH_ALLOW:=}"
: "${NFS_DISABLE:=1}"
: "${ADDRESS_FAMILY:=inet}"
: "${MAX_PORT:=60999}"
: "${TZ:=UTC}"
: "${LOG_LEVEL:=INFO}"
: "${UMASK:=0022}"
umask "${UMASK}" || true

print_overview() {
  banner "CONFIG OVERVIEW"
  echo "  VOLNAME=${VOLNAME}"
  echo "  MODE=${MODE}, VTYPE=${VTYPE}, REPLICA=${REPLICA}, TRANSPORT=${TRANSPORT}"
  echo "  VOL_OPTS=${VOL_OPTS:-<empty>}, AUTH_ALLOW=${AUTH_ALLOW:-<empty>}, NFS_DISABLE=${NFS_DISABLE}"
  echo "  ADDRESS_FAMILY=${ADDRESS_FAMILY}, MAX_PORT=${MAX_PORT}"
  echo "  UMASK=${UMASK}, TZ=${TZ}, LOG_LEVEL=${LOG_LEVEL}"
  echo -n "  HOST_BRICK*: "
  HB="$(env | awk -F= '/^HOST_BRICK[0-9]+=/{print \"    \" $0}' | sort -V 2>/dev/null || true)"
  if [[ -n "$HB" ]]; then printf "\n%s\n" "$HB"; else echo "    <none>"; fi
}

# create /bricks/brickN targets for each HOST_BRICKN
ensure_mount_points_from_env() {
  banner "ENSURE CONTAINER MOUNT TARGETS"
  local seen=0
  # iterate over env names starting with HOST_BRICK and digits
  while IFS='=' read -r name value; do
    case "$name" in HOST_BRICK[0-9]*) ;; *) continue ;; esac
    [[ -z "$value" ]] && continue
    idx="${name#HOST_BRICK}"
    tgt="/bricks/brick${idx}"
    mkdir -p "$tgt"
    echo "  + ${tgt} (from ${name})"
    seen=1
  done <<EOF
$(env | sort -V)
EOF
  [[ $seen -eq 0 ]] && echo "  ! no HOST_BRICK* set — will autodiscover /bricks/brick* or fallback to /bricks/brick1"
}

# return brick list (one per line), autodiscover only
brick_list() {
  # natural sort if available
  list="$(ls -d /bricks/brick* 2>/dev/null | { sort -V 2>/dev/null || cat; } )"
  if [[ -z "$list" ]]; then
    echo "/bricks/brick1"
  else
    printf "%s\n" "$list"
  fi
}

preflight_bricks() {
  banner "PREFLIGHT: BRICKS"
  bricks="$(brick_list)"
  echo "$bricks" | sed 's/^/  - /'
  count="$(printf "%s\n" "$bricks" | grep -c . || true)"

  if (( count < REPLICA )); then
    err "Not enough bricks: have ${count}, but REPLICA=${REPLICA}. Provide HOST_BRICK1..N or lower REPLICA."
    exit 1
  fi

  # write + xattr probe
  while IFS= read -r bp; do
    [[ -z "$bp" ]] && continue
    printf "  * %s: " "$bp"
    mkdir -p "$bp" || { echo "mkdir failed"; exit 1; }
    : > "${bp}/.writetest.$$" && rm -f "${bp}/.writetest.$$" || { echo "WRITE FAIL"; exit 1; }
    if command -v setfattr >/dev/null 2>&1 && command -v getfattr >/dev/null 2>&1; then
      if setfattr -n user._probe -v 1 "${bp}" 2>/dev/null && getfattr -n user._probe "${bp}" >/dev/null 2>&1; then
        echo "ok (write + xattr)"; setfattr -x user._probe "${bp}" 2>/dev/null || true
      else
        echo "ok (write), xattr WARN"; warn "xattr unsupported on ${bp}? Prefer ext4/xfs."
      fi
    else
      echo "ok (write)"
    fi
  done <<< "$bricks"
  ok "preflight passed"
}

start_glusterd() {
  banner "START GLUSTERD"
  info "starting glusterd..."
  glusterd
  vf="/etc/glusterfs/glusterd.vol"
  if [[ -f "$vf" ]]; then
    grep -q "option transport.address-family" "$vf" || echo "    option transport.address-family ${ADDRESS_FAMILY}" >> "$vf" || true
    grep -q "option max-port" "$vf" || echo "    option max-port ${MAX_PORT}" >> "$vf" || true
  fi
  for i in $(seq 1 60); do
    if gluster volume info >/dev/null 2>&1; then ok "glusterd is ready"; return 0; fi
    (( i % 5 == 0 )) && info "waiting for glusterd... (${i}s)"
    sleep 1
  done
  err "glusterd did not become ready in 60s"
  # dump logs if any
  set -- /var/log/glusterfs/*.log
  if [[ "$1" != "/var/log/glusterfs/*.log" ]]; then tail -n 200 "$@"; else echo "(no gluster logs yet)"; fi
  exit 1
}

apply_volume_tuning() {
  banner "APPLY VOLUME TUNING"
  OLDIFS="$IFS"; IFS=','
  for kv in $VOL_OPTS; do
    IFS="$OLDIFS"
    [[ -z "$kv" ]] && { IFS=','; continue; }
    key="${kv%%=*}"; val="${kv#*=}"
    if [[ -n "$key" && -n "$val" ]]; then
      info "set ${key}=${val}"
      gluster volume set "$VOLNAME" "$key" "$val" >/dev/null || true
    fi
    IFS=','
  done
  IFS="$OLDIFS"
  if [[ -n "${AUTH_ALLOW}" ]]; then
    info "set auth.allow=${AUTH_ALLOW}"
    gluster volume set "$VOLNAME" auth.allow "${AUTH_ALLOW}" >/dev/null || true
  fi
  if [[ "${NFS_DISABLE}" == "1" ]]; then
    info "set nfs.disable=on"
    gluster volume set "$VOLNAME" nfs.disable on >/dev/null || true
  fi
  ok "tuning applied"
}

ensure_volume_started() {
  banner "ENSURE VOLUME STARTED"
  if gluster volume info "$VOLNAME" >/dev/null 2>&1; then
    gluster volume start "$VOLNAME" >/dev/null 2>&1 || true
    apply_volume_tuning
    ok "volume ${VOLNAME} is ready"
  else
    err "volume ${VOLNAME} not found"; return 1
  fi
}

create_volume_solo() {
  banner "CREATE VOLUME (SOLO)"
  bricks="$(brick_list)"
  count="$(printf "%s\n" "$bricks" | grep -c . || true)"
  if (( count < REPLICA )); then
    err "Not enough bricks: have ${count}, but REPLICA=${REPLICA}. Provide HOST_BRICK1..N or lower REPLICA."
    exit 1
  fi
  host="${HOSTNAME:-$(hostname -s)}"
  spec=""
  while IFS= read -r bp; do
    [[ -z "$bp" ]] && continue
    spec="${spec} ${host}:${bp}"
  done <<< "$bricks"
  [[ "${ALLOW_FORCE_CREATE}" == "1" ]] && force_arg="force" || force_arg=""
  info "spec:${spec}"
  case "${VTYPE}" in
    replica) info "creating ${VOLNAME} (replica=${REPLICA}, transport=${TRANSPORT})";
             gluster volume create "${VOLNAME}" replica "${REPLICA}" transport "${TRANSPORT}" ${spec} ${force_arg} >/dev/null ;;
    *)       err "VTYPE='${VTYPE}' not supported"; exit 1 ;;
  esac
  gluster volume start "${VOLNAME}" >/dev/null
  apply_volume_tuning
  ok "created and started ${VOLNAME}"
}

# ----- main -----
print_overview
ensure_mount_points_from_env
preflight_bricks
start_glusterd

case "${MODE}" in
  init)
    banner "MODE: INIT"
    if [[ "${CREATE_VOLUME}" == "1" ]]; then
      if gluster volume info "${VOLNAME}" >/dev/null 2>&1; then
        info "volume exists — start & tune"; ensure_volume_started
      else
        create_volume_solo
      fi
    else
      info "CREATE_VOLUME=0 — will not create"
      gluster volume start "${VOLNAME}" >/dev/null 2>&1 || true
      apply_volume_tuning
    fi
    ;;
  brick)
    banner "MODE: BRICK"
    ;;
  *)
    err "Unknown MODE='${MODE}'"; exit 1 ;;
esac

banner "TAIL GLUSTER LOGS"
# Safe tail without arrays
set -- /var/log/glusterfs/*.log
if [[ "$1" == "/var/log/glusterfs/*.log" ]]; then
  echo "(no gluster logs yet)"
  exec sleep infinity
else
  exec tail -n+1 -F "$@"
fi
