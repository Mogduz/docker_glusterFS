#!/usr/bin/env bash
set -Eeo pipefail

log() {
  local ts; ts="$(date -u +'%Y-%m-%dT%H:%M:%S.%3NZ')"
  echo "[entry] $ts $*" >&2
}

trap 'rc=$?; log "trap.err rc=$rc last_cmd=${BASH_COMMAND}"; exit $rc' ERR
trap 'log "trap.exit rc=$?"' EXIT

# ---- Defaults / Tunables ----
: "${MODE:=solo}"                       # solo|raw (raw = kein Python-Bootstrap)
: "${MGMT_ADDR:=0.0.0.0}"
: "${BIND_ADDR:=}"                      # bevorzugte lokale IP (optional)
: "${DATA_PORT_START:=49152}"
: "${DATA_PORT_END:=49251}"
: "${RPC_ALLOW_INSECURE:=off}"
: "${SOLO_LOG_FORMAT:=text}"            # text|json
: "${SOLO_LOG_LEVEL:=INFO}"
: "${SOLO_DRY_RUN:=}"
: "${VOLUMES_YAML:=}"

prepare_glusterd_conf() {
  local conf="/etc/glusterfs/glusterd.vol"
  log "glusterd.conf.prepare path=$conf"
  if [[ ! -f "$conf" ]]; then
    log "WARN glusterd.vol fehlt – erzeuge Minimalvariante"
    cat >"$conf" <<'EOF'
volume management
  type mgmt/glusterd
  option working-directory /var/lib/glusterd
  option transport.socket.read-fail-log off
end-volume
EOF
  fi

  # Helper zum gezielten Einfügen/Entfernen
  add_opt() {
    local key="$1" val="$2"
    grep -qE "^\s*option\s+$key\s+" "$conf" \
      && sed -ri "s|^\s*option\s+$key\s+.*$|  option $key $val|" "$conf" \
      || sed -ri "s|^end-volume$|  option $key $val\nend-volume|" "$conf"
    log "glusterd.conf.set $key=$val"
  }
  del_opt() {
    local key="$1"
    sed -ri "/^\s*option\s+$key\s+/d" "$conf"
    log "glusterd.conf.del $key"
  }

  if [[ -n "$BIND_ADDR" ]]; then
    add_opt "transport.socket.bind-address" "$BIND_ADDR"
  else
    del_opt "transport.socket.bind-address"
  fi
  add_opt "base-port" "$DATA_PORT_START"
  add_opt "max-port" "$DATA_PORT_END"
  [[ "$RPC_ALLOW_INSECURE" == "on" ]] && add_opt "rpc-auth-allow-insecure" "on" || true
}

preflight_diags() {
  log "preflight.begin"
  log "env.MODE=$MODE env.BIND_ADDR=${BIND_ADDR:-<unset>} env.VOLUMES_YAML=${VOLUMES_YAML:-<unset>} " \
      "env.SOLO_LOG_LEVEL=$SOLO_LOG_LEVEL env.SOLO_LOG_FORMAT=$SOLO_LOG_FORMAT"
  (uname -a || true) | sed 's/^/[entry] kernel: /'
  (gluster --version || true) | sed 's/^/[entry] gluster: /'
  (python3 --version || true) | sed 's/^/[entry] python: /'
  (ip -o -4 addr show || true) | sed 's/^/[entry] ip4: /'
  (ip route || true) | sed 's/^/[entry] route: /'
  (ulimit -n || true) | sed 's/^/[entry] ulimit_nofile: /'
  (cat /etc/hosts || true) | sed 's/^/[entry] hosts: /'
  log "preflight.end"
}

start_glusterd() {
  local logf="/var/log/glusterd-foreground.log"
  mkdir -p /var/log || true
  log "glusterd.start log=$logf"
  # Wichtig: im Vordergrund bleiben, damit das Container-Leben an glusterd hängt
  glusterd --no-daemon --log-level INFO --log-file "$logf" &
  G_PID=$!
  log "glusterd.pid pid=$G_PID"
  # Readiness-Probe
  for i in {1..30}; do
    if gluster --mode=script volume list >/dev/null 2>&1; then
      log "glusterd.ready after=${i}s"
      return 0
    fi
    sleep 1
  done
  log "ERROR glusterd.timeout 30s"
  return 1
}

run_solo_bootstrap() {
  log "solo.begin"
  export BIND_ADDR BRICK_HOST  # BRICK_HOST darf vom Python ggf. „korrigiert“ werden
  [[ -n "$BIND_ADDR" && -z "$BRICK_HOST" ]] && export BRICK_HOST="$BIND_ADDR" || true

  local args=()
  [[ -n "$VOLUMES_YAML" ]] && args+=(--volumes-yaml "$VOLUMES_YAML")
  [[ -n "$SOLO_DRY_RUN"  ]] && args+=(--dry-run)
  args+=(--log-format "$SOLO_LOG_FORMAT" --log-level "$SOLO_LOG_LEVEL")
  [[ -n "$SOLO_REPORT" ]] && args+=(--report "$SOLO_REPORT")

  log "solo.exec /usr/local/bin/solo-startup.py args='${args[*]}'"
  /usr/bin/env python3 /usr/local/bin/solo-startup.py "${args[@]}"
  log "solo.end rc=$?"
}

main() {
  preflight_diags
  prepare_glusterd_conf
  start_glusterd

  if [[ "${MODE}" == "solo" ]]; then
    run_solo_bootstrap
    # Container lebt so lange wie glusterd lebt:
    log "wait.glusterd pid=$G_PID"
    wait "$G_PID"
    return 0
  fi

  log "MODE!=solo -> kein Python-Bootstrap (raw mode)"
  wait "$G_PID"
}

main "$@"
