#!/usr/bin/env bash
step_preflight() {
  step "Verzeichnisstruktur & Basismount prüfen"
  mkdir -p "$ROOT/etc" "$ROOT/glusterd" "$ROOT/logs" "$ROOT/bricks"
  if ! mountpoint -q "$ROOT"; then
    err "Persistenz-Mount $ROOT NICHT erkannt. Bitte mit -v /srv/gluster:$ROOT einhängen."
    exit 1
  fi
  ok "Persistenz-Mount erkannt: $ROOT"

  if [ -z "$(ls -A "$ROOT/etc" 2>/dev/null || true)" ]; then
    step "Seede Default-Konfigurationen nach $ROOT/etc"
    cp -a /opt/glusterfs-defaults/. "$ROOT/etc"/
    ok "Defaults kopiert"
  else
    ok "Config-Verzeichnis bereits befüllt"
  fi
}
