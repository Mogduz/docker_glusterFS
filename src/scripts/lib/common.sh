#!/usr/bin/env bash
# Shared defaults & helpers

# ---- defaults from env ----
ROOT="${GLUSTER_ROOT:-/gluster}"
NODE="${GLUSTER_NODE:-$(hostname -s)}"
CONFIG="${GLUSTER_CONFIG:-$ROOT/etc/cluster.yml}"
AUTO_PROBE="${AUTO_PROBE_PEERS:-true}"
AUTO_CREATE="${AUTO_CREATE_VOLUMES:-false}"
MANAGER_NODE="${MANAGER_NODE:-}"
FAIL_ON_UNMOUNTED_BRICK="${FAIL_ON_UNMOUNTED_BRICK:-true}"
BRICKS_ENV="${BRICKS:-}"
ALLOW_SINGLE_BRICK="${ALLOW_SINGLE_BRICK:-false}"

GLUSTER_WAIT_TRIES="${GLUSTER_WAIT_TRIES:-60}"
GLUSTER_WAIT_SLEEP="${GLUSTER_WAIT_SLEEP:-1}"
CREATE_RETRIES="${CREATE_RETRIES:-10}"
CREATE_RETRY_SLEEP="${CREATE_RETRY_SLEEP:-2}"
REWRITE_LOCAL_BRICKS="${REWRITE_LOCAL_BRICKS:-true}"
LOCAL_BRICK_HOST="${LOCAL_BRICK_HOST:-127.0.0.1}"
GLUSTER_FORCE_CREATE="${GLUSTER_FORCE_CREATE:-false}"

# ---- helpers ----
wait_for_glusterd() {
  local tries="$GLUSTER_WAIT_TRIES" sleep_s="$GLUSTER_WAIT_SLEEP"
  for i in $(seq 1 "$tries"); do
    if gluster --mode=script volume list >/dev/null 2>&1 || gluster pool list >/dev/null 2>&1; then
      ok "glusterd ist bereit (Try $i/$tries)"
      return 0
    fi
    sleep "$sleep_s"
  done
  err "glusterd nach $(($tries * $sleep_s))s nicht bereit."
  echo "=== letzte 200 Zeilen glusterd.log ==="; tail -n 200 "$ROOT/logs/glusterd.log" || true
  exit 98
}

run_with_retry() {
  local tries="$1" sleep_s="$2"; shift 2
  for n in $(seq 1 "$tries"); do
    if "$@"; then return 0; fi
    warn "Retry $n/$tries: $*"
    sleep "$sleep_s"
  done
  return 1
}

check_volume_safety() {
  local idx="$1" name="$2" vtype="$3"; shift 3
  local -a bricks=( "$@" ); local n="${#bricks[@]}"
  if (( n == 1 )); then
    if [[ "$ALLOW_SINGLE_BRICK" == "true" ]]; then
      warn "Volume '${name}' hat NUR 1 Brick (kein Redundanz/Quorum). ALLOW_SINGLE_BRICK=true → fortsetzen."
    else
      err  "Volume '${name}' hat NUR 1 Brick. Setze -e ALLOW_SINGLE_BRICK=true oder füge Bricks hinzu."
      exit 42
    fi
  fi
  if [[ "$vtype" == "replicate" ]]; then
    local replica arbiter; replica="$(yq -r ".volumes[$idx].replica // \"\"" "$CONFIG")"
    arbiter="$(yq -r ".volumes[$idx].arbiter // \"\"" "$CONFIG")"
    [[ -z "$replica" || "$replica" == "null" ]] && { err "replicate-Volume '${name}' ohne 'replica'"; exit 43; }
    (( n % replica == 0 )) || { err "replicate '${name}': Brick-Anzahl ($n) kein Vielfaches von replica ($replica)"; exit 44; }
    if [[ -n "$arbiter" && "$arbiter" != "null" && $arbiter -ge $replica ]]; then
      warn "Arbiter ($arbiter) >= replica ($replica) bei '${name}' – prüfen."
    fi
  fi
  if [[ "$vtype" == "disperse" ]]; then
    local disperse redundancy
    disperse="$(yq -r ".volumes[$idx].disperse_count // \"\"" "$CONFIG")"
    redundancy="$(yq -r ".volumes[$idx].redundancy // \"\"" "$CONFIG")"
    [[ -z "$disperse" || -z "$redundancy" || "$disperse" == "null" || "$redundancy" == "null" ]] && { err "disperse '${name}' ohne Parameter"; exit 45; }
    (( n == disperse )) || { err "disperse '${name}': Brick-Anzahl ($n) != disperse_count ($disperse)"; exit 46; }
  fi
}

rewrite_local_bricks() {
  local -a in=( "$@" ) out=()
  local self_ip resolved_ip
  self_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  resolved_ip="$(getent hosts "$NODE" 2>/dev/null | awk '{print $1}' | head -1 || true)"
  for spec in "${in[@]}"; do
    local host="${spec%%:*}" path="${spec#*:}"
    if [[ "$REWRITE_LOCAL_BRICKS" == "true" ]] && { [[ "$host" == "$NODE" ]] || [[ "$host" == "localhost" ]] || [[ "$host" == "$resolved_ip" ]] || [[ "$host" == "$self_ip" ]]; }; then
      local new="${LOCAL_BRICK_HOST}:$path"
      [[ "$new" != "$spec" ]] && log "Rewriting local brick host: $spec → $new"
      out+=( "$new" )
    else
      out+=( "$spec" )
    fi
  done
  printf "%s\n" "${out[@]}"
}
