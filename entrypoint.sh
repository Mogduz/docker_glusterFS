\
    #!/usr/bin/env bash
    set -euo pipefail

    # -------------------- tiny logger --------------------
    ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
    log() { printf "%s [%s] %s\n" "$(ts)" "$1" "$2"; }
    info() { log INFO "$*"; }
    warn() { log WARN "$*"; }
    err() { log ERROR "$*"; }
    ok()  { log OK "$*"; }

    # -------------------- helpers --------------------
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
    : "${BRICK_PATHS:=}"
    : "${BRICK_PATH:=}"

    umask "${UMASK}" || true


ensure_mount_points_from_env() {
  # For each HOST_BRICK{N} env var, create /bricks/brick{N} as mountpoint
  # This does NOT create Docker mounts; it only ensures the target directories exist.
  # Docker Compose binds the host paths to these targets via the service volumes.
  local line name value idx
  while IFS='=' read -r name value; do
    [[ "$name" =~ ^HOST_BRICK([0-9]+)$ ]] || continue
    idx="${BASH_REMATCH[1]}"
    [[ -z "${value}" ]] && continue
    mkdir -p "/bricks/brick${idx}"
  done < <(env | grep -E '^HOST_BRICK[0-9]+=' | sort -V)
}


    # Build list of brick paths from BRICK_PATHS or fallback BRICK_PATH
    brick_list() {
  # If BRICK_PATHS is provided explicitly, use it
  if [[ -n "${BRICK_PATHS}" ]]; then
    IFS=',' read -r -a _bps <<< "${BRICK_PATHS}"
    printf "%s
" "${_bps[@]}"
    return 0
  fi
  # Backward-compatible fallback env
  if [[ -n "${BRICK_PATH}" ]]; then
    IFS=',' read -r -a _bps <<< "${BRICK_PATH}"
    printf "%s
" "${_bps[@]}"
    return 0
  fi
  # Auto-discover: scan /bricks/brick* that exist
  local discovered=()
  shopt -s nullglob
  for p in /bricks/brick*; do
    [[ -d "$p" ]] && discovered+=("$p")
  done
  shopt -u nullglob
  if (( ${#discovered[@]} == 0 )); then
    # Final fallback: assume /bricks/brick1 exists or will be created
    discovered=(/bricks/brick1)
  fi
  # Natural sort (brick1, brick2, brick10): use sort -V if available
  if command -v sort >/dev/null 2>&1; then
    printf "%s
" "${discovered[@]}" | sort -V
  else
    printf "%s
" "${discovered[@]}"
  fi
}" ]]; then
        IFS=',' read -r -a _bps <<< "${BRICK_PATHS}"
      elif [[ -n "${BRICK_PATH}" ]]; then
        IFS=',' read -r -a _bps <<< "${BRICK_PATH}"
      else
        _bps=(/bricks/brick1)
      fi
      printf "%s\n" "${_bps[@]}"
    }

    ensure_bricks() {
      local bp
      while IFS= read -r bp; do
        [[ -z "$bp" ]] && continue
        mkdir -p "$bp"
      done < <(brick_list)
    }

    start_glusterd() {
      info "Starting glusterd…"
      # Start glusterd as daemon
      glusterd
      # Patch glusterd volfile for address family / port cap if available
      local volfile="/etc/glusterfs/glusterd.vol"
      if [[ -f "$volfile" ]]; then
        grep -q "option transport.address-family" "$volfile" || echo "    option transport.address-family ${ADDRESS_FAMILY}" >> "$volfile" || true
        grep -q "option max-port" "$volfile" || echo "    option max-port ${MAX_PORT}" >> "$volfile" || true
      fi
      # Wait until CLI works
      local i
      for i in {1..60}; do
        if gluster volume info >/dev/null 2>&1; then
          ok "glusterd is ready"
          return 0
        fi
        sleep 1
      done
      err "glusterd did not become ready in time"; exit 1
    }

    apply_volume_tuning() {
      # Apply volume options from VOL_OPTS (comma-separated key=value)
      IFS=',' read -r -a _opt_pairs <<< "${VOL_OPTS}"
      local kv key val
      for kv in "${_opt_pairs[@]}"; do
        [[ -z "$kv" ]] && continue
        key="${kv%%=*}"; val="${kv#*=}"
        if [[ -n "$key" && -n "$val" ]]; then
          gluster volume set "$VOLNAME" "$key" "$val" >/dev/null || true
        fi
      done
      # If AUTH_ALLOW is provided, restrict clients
      if [[ -n "${AUTH_ALLOW}" ]]; then
        gluster volume set "$VOLNAME" auth.allow "${AUTH_ALLOW}" >/dev/null || true
      fi
      # Optionally disable legacy NFS translator
      if [[ "${NFS_DISABLE}" == "1" ]]; then
        gluster volume set "$VOLNAME" nfs.disable on >/dev/null || true
      fi
    }

    ensure_volume_started() {
      if gluster volume info "$VOLNAME" >/dev/null 2>&1; then
        gluster volume start "$VOLNAME" >/dev/null 2>&1 || true
        apply_volume_tuning
        ok "Volume ${VOLNAME} is ready"
      else
        err "Volume ${VOLNAME} not found"; return 1
      fi
    }

    create_volume_solo() {
      local -a arr spec
      mapfile -t arr < <(brick_list)
      ensure_bricks
      local host="${HOSTNAME:-$(hostname -s)}"
      spec=()
      local bp
      for bp in "${arr[@]}"; do
        [[ -z "$bp" ]] && continue
        spec+=("${host}:${bp}")
      done
      local force_arg=""
      [[ "${ALLOW_FORCE_CREATE}" == "1" ]] && force_arg="force"

      case "${VTYPE}" in
        replica)
          info "Creating volume: ${VOLNAME} (replica=${REPLICA}, transport=${TRANSPORT}) with bricks: ${spec[*]}"
          gluster volume create "${VOLNAME}" replica "${REPLICA}" transport "${TRANSPORT}" "${spec[@]}" ${force_arg} >/dev/null
          ;;
        *)
          err "VTYPE='${VTYPE}' not supported in solo setup"; exit 1;;
      esac

      gluster volume start "${VOLNAME}" >/dev/null
      apply_volume_tuning
      ok "Created and started volume ${VOLNAME}"
    }

    # -------------------- main --------------------
ensure_mount_points_from_env
    start_glusterd

    case "${MODE}" in
      init)
        info "Mode: INIT"
        if [[ "${CREATE_VOLUME}" == "1" ]]; then
          if gluster volume info "${VOLNAME}" >/dev/null 2>&1; then
            info "Volume ${VOLNAME} exists — starting & tuning"
            ensure_volume_started
          else
            create_volume_solo
          fi
        else
          info "CREATE_VOLUME=0 — will not create; ensuring bricks exist and trying to start the volume if present"
          ensure_bricks
          gluster volume start "${VOLNAME}" >/dev/null 2>&1 || true
          apply_volume_tuning
        fi
        ;;
      brick)
        info "Mode: BRICK"
        ensure_bricks
        ;;
      *)
        err "Unknown MODE='${MODE}'"; exit 1;;
    esac

    ok "Tail Gluster logs:"
    exec tail -F /var/log/glusterfs/*.log
