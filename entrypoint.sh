#!/usr/bin/env bash
# shellcheck shell=bash
# Communicative Gluster entrypoint with diagnostics & safeguards

# ---- Strict mode + error trap ----
set -Eeuo pipefail
trap 'rc=$?; echo "$(date -u +%FT%TZ) [ERROR] Exit $rc at ${BASH_SOURCE[0]}:${LINENO} :: ${BASH_COMMAND}"; exit $rc' ERR

# Optional debug tracing
: "${DEBUG:=0}"
if [[ "$DEBUG" == "1" ]]; then set -x; fi

# ---- Tiny logger helpers ----
ts()   { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log()  { printf "%s [%s] %s\n" "$(ts)" "$1" "$2"; }
info() { log INFO "$*"; }
warn() { log WARN "$*"; }
err()  { log ERROR "$*"; }
ok()   { log OK "$*"; }
banner(){ printf "\n%s [PHASE] %s\n\n" "$(ts)" "$*"; }

# ---- Config (ENV) with safe defaults ----
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
# Legacy/optional inputs (not required in env-only mode)
: "${BRICK_PATHS:=}"
: "${BRICK_PATH:=}"

umask "${UMASK}" || true

# ---- Verbose config overview ----
print_overview() {
  banner "CONFIG OVERVIEW"
  echo "  VOLNAME=${VOLNAME}"
  echo "  MODE=${MODE}, VTYPE=${VTYPE}, REPLICA=${REPLICA}, TRANSPORT=${TRANSPORT}"
  echo "  VOL_OPTS=${VOL_OPTS:-<empty>}, AUTH_ALLOW=${AUTH_ALLOW:-<empty>}, NFS_DISABLE=${NFS_DISABLE}"
  echo "  ADDRESS_FAMILY=${ADDRESS_FAMILY}, MAX_PORT=${MAX_PORT}"
  echo "  UMASK=${UMASK}, TZ=${TZ}, LOG_LEVEL=${LOG_LEVEL}"
  # Show HOST_BRICK* discovered from environment
  echo -n "  HOST_BRICK*: "
  env | grep -E '^HOST_BRICK[0-9]+=' | sort -V | sed 's/^/    /' || echo "    <none>"
  # Show BRICK_PATHS/BRICK_PATH if provided (legacy)
  [[ -n "${BRICK_PATHS}" ]] && echo "  BRICK_PATHS=${BRICK_PATHS}"
  [[ -n "${BRICK_PATH}"  ]] && echo "  BRICK_PATH=${BRICK_PATH}"
}

# ---- Create /bricks/brickN for each HOST_BRICKN ----
ensure_mount_points_from_env() {
  banner "ENSURE CONTAINER MOUNT TARGETS"
  local count=0
  while IFS='=' read -r name value; do
    [[ "$name" =~ ^HOST_BRICK([0-9]+)$ ]] || continue
    local idx="${BASH_REMATCH[1]}"
    [[ -z "${value}" ]] && continue
    local target="/bricks/brick${idx}"
    mkdir -p "${target}"
    echo "  + ${target} (from ${name})"
    ((count++)) || true
  done < <(env | grep -E '^HOST_BRICK[0-9]+=' | sort -V)
  if (( count == 0 )); then
    echo "  ! No HOST_BRICK* variables set — will rely on autodiscovery or default /bricks/brick1"
  fi
}

# ---- Determine brick list ----
brick_list() {
  if [[ -n "${BRICK_PATHS}" ]]; then
    IFS=',' read -r -a _bps <<< "${BRICK_PATHS}"
    printf "%s\n" "${_bps[@]}"
    return 0
  fi
  if [[ -n "${BRICK_PATH}" ]]; then
    IFS=',' read -r -a _bps <<< "${BRICK_PATH}"
    printf "%s\n" "${_bps[@]}"
    return 0
  fi
  # Autodiscover /bricks/brick* (natural sort)
  shopt -s nullglob
  local arr=(/bricks/brick*)
  shopt -u nullglob
  if (( ${#arr[@]} == 0 )); then
    arr=(/bricks/brick1)
  fi
  if command -v sort >/dev/null 2>&1; then
    printf "%s\n" "${arr[@]}" | sort -V
  else
    printf "%s\n" "${arr[@]}"
  fi
}

# ---- Preflight checks for bricks ----
preflight_bricks() {
  banner "PREFLIGHT: BRICKS"
  local -a arr
  mapfile -t arr < <(brick_list)
  echo "  discovered container brick paths:"
  printf "    - %s\n" "${arr[@]}"

  # Safety: ensure we have at least REPLICA bricks
  if (( ${#arr[@]} < REPLICA )); then
    err "Not enough bricks: have ${#arr[@]}, but REPLICA=${REPLICA}."
    echo "  Hints:"
    echo "    - Set HOST_BRICK1..N in .env and ensure compose binds them."
    echo "    - Or lower REPLICA to match brick count."
    exit 1
  fi

  # Ensure existence, writeability, and (best-effort) xattr support
  local bp
  for bp in "${arr[@]}"; do
    printf "  * %s: " "$bp"
    mkdir -p "$bp" || { echo "mkdir failed"; exit 1; }
    # write test
    if ! ( : > "${bp}/.writetest.$$" && rm -f "${bp}/.writetest.$$" ); then
      echo "WRITE FAIL"; exit 1
    fi
    # xattr test (best effort; ignore failure but warn)
    if command -v setfattr >/dev/null 2>&1 && command -v getfattr >/dev/null 2>&1; then
      if setfattr -n user._probe -v 1 "${bp}" 2>/dev/null && getfattr -n user._probe "${bp}" >/dev/null 2>&1; then
        echo "ok (write + xattr)"
        setfattr -x user._probe "${bp}" 2>/dev/null || true
      else
        echo "ok (write), xattr WARN"
        warn "xattr seems unsupported on ${bp}. Gluster may fail later; ensure host FS supports xattrs (ext4/xfs)."
      fi
    else
      echo "ok (write)"
    fi
    # mountpoint hint (optional)
    if command -v mountpoint >/dev/null 2>&1 && mountpoint -q "$bp"; then
      echo "    note: $bp is a mountpoint."
    fi
  done
  ok "preflight passed"
}

# ---- Start glusterd and wait ----
start_glusterd() {
  banner "START GLUSTERD"
  info "starting glusterd..."
  glusterd
  local volfile="/etc/glusterfs/glusterd.vol"
  if [[ -f "$volfile" ]]; then
    grep -q "option transport.address-family" "$volfile" || echo "    option transport.address-family ${ADDRESS_FAMILY}" >> "$volfile" || true
    grep -q "option max-port" "$volfile" || echo "    option max-port ${MAX_PORT}" >> "$volfile" || true
  fi
  for i in {1..60}; do
    if gluster volume info >/dev/null 2>&1; then
      ok "glusterd is ready"
      return 0
    fi
    (( i % 5 == 0 )) && info "waiting for glusterd... (${i}s)"
    sleep 1
  done
  err "glusterd did not become ready in 60s"
  echo "---- last gluster logs (if any) ----"
  shopt -s nullglob; files=(/var/log/glusterfs/*.log); shopt -u nullglob
  (( ${#files[@]} > 0 )) && tail -n 200 "${files[@]}" || echo "(no gluster logs yet)"
  exit 1
}

apply_volume_tuning() {
  banner "APPLY VOLUME TUNING"
  IFS=',' read -r -a _opt_pairs <<< "${VOL_OPTS}"
  local kv key val
  for kv in "${_opt_pairs[@]}"; do
    [[ -z "$kv" ]] && continue
    key="${kv%%=*}"; val="${kv#*=}"
    if [[ -n "$key" && -n "$val" ]]; then
      info "set ${key}=${val}"
      gluster volume set "$VOLNAME" "$key" "$val" >/dev/null || true
    fi
  done
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
  local -a arr spec
  mapfile -t arr < <(brick_list)
  # Safety
  if (( ${#arr[@]} < REPLICA )); then
    err "Not enough bricks: have ${#arr[@]}, but REPLICA=${REPLICA}."
    echo "  Provide HOST_BRICK1..N or lower REPLICA."
    exit 1
  fi

  local host="${HOSTNAME:-$(hostname -s)}"
  spec=()
  local bp
  for bp in "${arr[@]}"; do
    [[ -z "$bp" ]] && continue
    spec+=("${host}:${bp}")
  done
  info "spec: ${spec[*]}"
  local force_arg=""; [[ "${ALLOW_FORCE_CREATE}" == "1" ]] && force_arg="force"

  case "${VTYPE}" in
    replica)
      info "creating ${VOLNAME} (replica=${REPLICA}, transport=${TRANSPORT})"
      gluster volume create "${VOLNAME}" replica "${REPLICA}" transport "${TRANSPORT}" "${spec[@]}" ${force_arg} >/dev/null
      ;;
    *)
      err "VTYPE='${VTYPE}' not supported in this setup"; exit 1;;
  esac

  gluster volume start "${VOLNAME}" >/dev/null
  apply_volume_tuning
  ok "created and started ${VOLNAME}"
}

# -------------------- main --------------------
print_overview
ensure_mount_points_from_env
preflight_bricks
start_glusterd

case "${MODE}" in
  init)
    banner "MODE: INIT"
    if [[ "${CREATE_VOLUME}" == "1" ]]; then
      if gluster volume info "${VOLNAME}" >/dev/null 2>&1; then
        info "volume exists — start & tune"
        ensure_volume_started
      else
        create_volume_solo
      fi
    else
      info "CREATE_VOLUME=0 — will not create; try to start and tune if present"
      mapfile -t _ >/dev/null < <(brick_list) # trigger discovery/logs
      gluster volume start "${VOLNAME}" >/dev/null 2>&1 || true
      apply_volume_tuning
    fi
    ;;
  brick)
    banner "MODE: BRICK"
    # Nothing to do beyond ensuring mount targets; glusterd will serve bricks
    ;;
  *)
    err "Unknown MODE='${MODE}'"; exit 1;;
esac

banner "TAIL GLUSTER LOGS"
# Safe tail: do not crash if no log files exist yet
exec bash -lc 'shopt -s nullglob; files=(/var/log/glusterfs/*.log); \
  if (( ${#files[@]} == 0 )); then echo "(no gluster logs yet)"; exec sleep infinity; \
  else exec tail -n+1 -F "${files[@]}"; fi'
