#!/usr/bin/env bash
step_glusterd() {
  step "Starte glusterd (Management-Daemon)"
  /usr/sbin/glusterd -N &
  GLUSTERD_PID=$!
  export GLUSTERD_PID
  ok "glusterd PID: $GLUSTERD_PID"

  step "Warte auf Readiness von glusterd"
  wait_for_glusterd
  ok "Gluster CLI verfügbar"

  local self_ip resolved_ip
  self_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  resolved_ip="$(getent hosts "$NODE" 2>/dev/null | awk '{print $1}' | head -1 || true)"
  log "Self IP: ${self_ip:-<unk>}, ${NODE} → ${resolved_ip:-<unk>}"
}
