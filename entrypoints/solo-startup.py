#!/usr/bin/env python3
import sys, os, time, subprocess, shlex
from typing import Dict, List, Any
try:
    import yaml  # type: ignore
except Exception as e:
    print(f"[solo-startup:ERROR] PyYAML fehlt: {e}", file=sys.stderr)
    sys.exit(1)

GLUSTER = os.environ.get("GLUSTER_CLI", "/usr/sbin/gluster")

def run(cmd: List[str], check=True, capture_output=False) -> subprocess.CompletedProcess:
    print("[solo-startup] $", " ".join(shlex.quote(c) for c in cmd), flush=True)
    return subprocess.run(cmd, check=check, text=True, capture_output=capture_output)

def ensure_peer_ok() -> None:
    # In Solo-Setup ist Peer-Liste egal, aber wir warten bis das CLI antwortet
    for _ in range(60):
        try:
            cp = run([GLUSTER, "--mode=script", "volume", "list"], check=False, capture_output=True)
            if cp.returncode == 0:
                return
        except Exception:
            pass
        time.sleep(1)
    print("[solo-startup:ERROR] gluster CLI nicht bereit", file=sys.stderr)
    sys.exit(1)

def create_or_update_volume(name: str, spec: Dict[str, Any]) -> None:
    bricks: List[str] = spec.get("bricks", [])
    if not bricks:
        print(f"[solo-startup:WARN] Volume {name}: keine bricks angegeben, überspringe", file=sys.stderr)
        return
    replica = int(spec.get("replica", 1))
        # Ensure brick directories exist
        for b in bricks:
            try:
                os.makedirs(b, exist_ok=True)
            except Exception as e:
                print(f"[solo-startup:WARN] Konnte Brick-Verzeichnis {b} nicht anlegen: {e}", file=sys.stderr)

    transport = str(spec.get("transport", "tcp"))
    force = bool(spec.get("force", True))
    options: Dict[str, str] = spec.get("options", {}) or {}

    # Existiert das Volume?
    cp = run([GLUSTER, "--mode=script", "volume", "info", name], check=False, capture_output=True)
    exists = cp.returncode == 0 and ("Volume Name: " + name) in cp.stdout

    if not exists:
        cmd = [GLUSTER, "--mode=script", "volume", "create", name]
        if replica > 1:
            cmd += ["replica", str(replica)]
        cmd += ["transport", transport]
        cmd += bricks
        if force:
            cmd += ["force"]
        run(cmd)
    else:
        print(f"[solo-startup] Volume {name} existiert bereits, führe ggf. Optionen nach.", flush=True)

    # Optionen setzen
    for k, v in options.items():
        run([GLUSTER, "--mode=script", "volume", "set", name, str(k), str(v)])

    # Starten (wenn nicht bereits)
    cp = run([GLUSTER, "--mode=script", "volume", "status", name], check=False, capture_output=True)
    started = cp.returncode == 0
    if not started:
        run([GLUSTER, "--mode=script", "volume", "start", name])

def main(path: str) -> None:
    if not os.path.exists(path) or os.path.getsize(path) == 0:
        print(f"[solo-startup:WARN] YAML {path} nicht vorhanden/leer – nichts zu tun.", file=sys.stderr)
        return
    with open(path, "r", encoding="utf-8") as f:
        data = yaml.safe_load(f) or {}
    # Schema: { volumes: [ { name, bricks: [...], replica: 1|2|..., transport: "tcp", options: {k:v} } ] }
    vols = data.get("volumes", [])
    if not isinstance(vols, list) or not vols:
        print(f"[solo-startup:WARN] Keine volumes in {path} – nichts zu tun.", file=sys.stderr)
        return

    ensure_peer_ok()

    for v in vols:
        if not isinstance(v, dict) or "name" not in v:
            print(f"[solo-startup:WARN] Überspringe ungültigen Volumeneintrag: {v}", file=sys.stderr)
            continue
        name = str(v["name"])
        create_or_update_volume(name, v)

    print("[solo-startup] Fertig.", flush=True)

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: solo-startup.py /etc/gluster/volumes.yml", file=sys.stderr)
        sys.exit(64)
    main(sys.argv[1])
