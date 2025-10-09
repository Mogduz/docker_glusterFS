    #!/usr/bin/env bash
    # GlusterFS container healthcheck (verbos, fehlertolerant)
    # - client: prüft, ob konfigurierte Mounts aktiv sind
    # - server: prüft, ob glusterd läuft und CLI antwortet
    set -Eeuo pipefail

    log() { printf '%s [%s] %s\n' "$(date -u +'%FT%TZ')" "$1" "$2" >&2; }
    die() { log "ERROR" "$1"; exit "${2:-1}"; }

    CFG_PATH="${CONFIG_PATH:-/etc/gluster-container/config.yaml}"
    ROLE="${ROLE:-}"

    # Versuche Rolle aus YAML abzuleiten, falls nicht gesetzt
    if [[ -z "$ROLE" && -f "$CFG_PATH" ]]; then
      ROLE="$(python3 - <<'PY' 2>/dev/null || true
import sys, yaml, os
try:
    with open(os.environ.get("CONFIG_PATH", "/etc/gluster-container/config.yaml"), "r", encoding="utf-8") as f:
        cfg = yaml.safe_load(f) or {}
    print((cfg.get("role") or "server").lower())
except Exception:
    print("server")
PY
)"
    fi

    ROLE="${ROLE:-server}"

    if [[ "$ROLE" == "client" ]]; then
      # Ziel-Mounts ermitteln
      TARGETS="$(python3 - <<'PY' 2>/dev/null || true
import sys, yaml, os
cfg_path = os.environ.get("CONFIG_PATH", "/etc/gluster-container/config.yaml")
targets = []
try:
    with open(cfg_path, "r", encoding="utf-8") as f:
        cfg = yaml.safe_load(f) or {}
    for m in (cfg.get("mounts") or []):
        t = m.get("target") or "/mnt/gluster"
        targets.append(t)
except Exception:
    pass
print("\n".join(targets))
PY
)"
      if [[ -z "$TARGETS" ]]; then
        die "Keine Mount-Ziele konfiguriert (client-Modus?)" 2
      fi
      while IFS= read -r t; do
        [[ -z "$t" ]] && continue
        if mountpoint -q -- "$t"; then
          log "INFO" "Mount OK: $t"
        else
          die "Mount fehlt/unhealthy: $t" 3
        fi
      done <<< "$TARGETS"
      exit 0
    else
      # Server-Checks
      if pgrep -x glusterd >/dev/null 2>&1; then
        :
      else
        die "glusterd Prozess nicht gefunden" 4
      fi
      if gluster volume list >/dev/null 2>&1 || gluster peer status >/dev/null 2>&1; then
        log "INFO" "glusterd/CLI OK"
        exit 0
      else
        die "gluster CLI antwortet nicht" 5
      fi
    fi
