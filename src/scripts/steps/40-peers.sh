#!/usr/bin/env bash
step_peers() {
  if [[ -f "$CONFIG" && "$AUTO_PROBE" == "true" ]]; then
    step "Peers aus YAML proben"
    local has_peer=false
    while IFS= read -r peer; do
      [[ -z "$peer" || "$peer" == "null" || "$peer" == "$NODE" ]] && continue
      has_peer=true
      for i in {1..10}; do
        if gluster peer probe "$peer" >/dev/null 2>&1; then ok "Peer geprobt: $peer"; break; fi
        warn "Peer probe fehlgeschlagen ($peer), Versuch $i/10 – erneut in 2s…"; sleep 2
      done
    done < <(yq -r '.peers[]? // empty' "$CONFIG")
    [[ "$has_peer" == false ]] && warn "Keine externen Peers in YAML gefunden (oder nur Self)."
  else
    log "Peer-Probing übersprungen (kein YAML oder AUTO_PROBE_PEERS=false)"
  fi
}
