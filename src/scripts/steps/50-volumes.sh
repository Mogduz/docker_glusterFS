#!/usr/bin/env bash
step_volumes() {
  if [[ "$AUTO_CREATE" != "true" ]]; then
    log "Volume-Management deaktiviert (AUTO_CREATE_VOLUMES=false)"
    return 0
  fi
  step "Volume-Management (create/set/start)"
  [[ -z "$MANAGER_NODE" && -f "$CONFIG" ]] && MANAGER_NODE="$(yq -r '.manager_node // ""' "$CONFIG")"
  if [[ -n "$MANAGER_NODE" && "$MANAGER_NODE" != "$NODE" ]]; then
    log "Dieser Node ist NICHT der Manager (Manager: '$MANAGER_NODE') – überspringe Volume-Management."
    return 0
  fi
  [[ -f "$CONFIG" ]] || { warn "AUTO_CREATE_VOLUMES=true, aber keine YAML gefunden – nichts zu tun."; return 0; }

  local COUNT; COUNT="$(yq -r '.volumes | length // 0' "$CONFIG" 2>/dev/null || echo 0)"
  log "Gefundene Volume-Definitionen: $COUNT"

  for ((i=0; i<COUNT; i++)); do
    local name vtype transport
    name="$(yq -r ".volumes[$i].name" "$CONFIG")"
    [[ -z "$name" || "$name" == "null" ]] && { warn "Volume ohne Namen (Index $i) – skip"; continue; }
    vtype="$(yq -r ".volumes[$i].type // \"distribute\"" "$CONFIG")"
    transport="$(yq -r ".volumes[$i].transport // \"tcp\"" "$CONFIG")"

    mapfile -t bricks_raw < <(yq -r ".volumes[$i].bricks[]? // empty" "$CONFIG")
    (( ${#bricks_raw[@]} )) || { warn "Volume '$name' ohne bricks – skip"; continue; }

    check_volume_safety "$i" "$name" "$vtype" "${bricks_raw[@]}"
    mapfile -t bricks < <(rewrite_local_bricks "${bricks_raw[@]}")

    if gluster volume info "$name" >/dev/null 2>&1; then
      ok "Volume existiert bereits: ${name} – setze Optionen & starte falls nötig."
    else
      local cmd=(gluster volume create "$name")
      case "$vtype" in
        replicate)
          local replica arbiter
          replica="$(yq -r ".volumes[$i].replica // \"\"" "$CONFIG")"
          arbiter="$(yq -r ".volumes[$i].arbiter // \"\"" "$CONFIG")"
          [[ -n "$replica" && "$replica" != "null" ]] && cmd+=("replica" "$replica")
          [[ -n "$arbiter" && "$arbiter" != "null" ]] && cmd+=("arbiter" "$arbiter")
          ;;
        disperse)
          local disperse redundancy
          disperse="$(yq -r ".volumes[$i].disperse_count // \"\"" "$CONFIG")"
          redundancy="$(yq -r ".volumes[$i].redundancy // \"\"" "$CONFIG")"
          [[ -n "$disperse" && -n "$redundancy" && "$disperse" != "null" && "$redundancy" != "null" ]] && cmd+=("disperse" "$disperse" "redundancy" "$redundancy")
          ;;
        distribute|*) ;;
      esac
      cmd+=("transport" "$transport")
      cmd+=("${bricks[@]}")
      [[ "$GLUSTER_FORCE_CREATE" == "true" ]] && cmd+=("force")
      log "Erzeuge Volume mit Befehl:\n  ${C_DIM}${cmd[*]}${C_RESET}"

      run_with_retry "$CREATE_RETRIES" "$CREATE_RETRY_SLEEP" "${cmd[@]}" \
        || { err "Volume-Create für '$name' scheitert nach ${CREATE_RETRIES} Versuchen."; tail -n 200 "$ROOT/logs/glusterd.log" || true; exit 97; }
    fi

    yq -r ".volumes[$i].options // {} | to_entries[]? | \"\(.key) \(.value)\"" "$CONFIG" \
    | while read -r key val; do
        [[ -z "$key" || "$key" == "null" ]] && continue
        log "Setze Option: ${name} ${key}=${val}"
        gluster volume set "$name" "$key" "$val" || true
      done

    if gluster volume status "$name" >/dev/null 2>&1; then
      ok "Volume läuft: $name"
    else
      log "Starte Volume: $name"; gluster volume start "$name" || true
    fi
  done
}
