#!/usr/bin/env bash
step_bricks() {
  step "Bricks ermitteln (YAML + ENV)"
  declare -ag BRICK_PATHS=()

  if [[ -f "$CONFIG" ]]; then
    log "Lese YAML: $CONFIG"
    while IFS= read -r b; do [[ -n "$b" && "$b" != "null" ]] && BRICK_PATHS+=("$b"); done \
      < <(yq -r '.local_bricks[]? // empty' "$CONFIG")
  else
    warn "Keine YAML-Konfig gefunden (optional): $CONFIG"
  fi

  if [[ -n "$BRICKS_ENV" ]]; then
    IFS=',' read -r -a extra <<< "$BRICKS_ENV"
    for raw in "${extra[@]}"; do
      b="$(echo "$raw" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      [[ -z "$b" || "$b" == "null" ]] && continue
      BRICK_PATHS+=("$b")
    done
  fi

  if ((${#BRICK_PATHS[@]} > 0)); then
    mapfile -t BRICK_PATHS < <(printf "%s\n" "${BRICK_PATHS[@]}" | awk '!seen[$0]++')
    ok "Gefundene Bricks (${#BRICK_PATHS[@]}):"; for b in "${BRICK_PATHS[@]}"; do echo "  - $b"; done
  else
    warn "Keine Bricks angegeben. YAML .local_bricks oder ENV BRICKS verwenden."
  fi

  step "Bricks anlegen & Bind-Mounts verifizieren"
  for brick in "${BRICK_PATHS[@]}"; do
    mkdir -p "$brick"
    if mountpoint -q "$brick"; then ok "Brick gemountet: $brick"; else
      if [[ "$FAIL_ON_UNMOUNTED_BRICK" == "true" ]]; then
        err "Brick NICHT gemountet: $brick  (Host: -v /host/pfad:$brick)"; exit 1
      else
        warn "Brick nicht gemountet, verwende Container-FS (nur Test): $brick"
      fi
    fi
  done
}
