\
    #!/usr/bin/env python3

"""
solo-startup.py
- Liest volumes.yml (Pfad aus $VOLUMES_YAML oder Fallbacks)
- Ermittelt Brick-Verzeichnisse aus $BRICKS oder Default (/bricks/brick{1..replica})
- Erstellt fehlende Dirs, baut Brick-Subdirs <brick>/<volname>
- Erzeugt/konfiguriert Gluster-Volumes idempotent
"""
import os, sys, subprocess, shlex
from pathlib import Path
try:
    import yaml
except Exception as e:
    print("[solo] FATAL: PyYAML (python3-yaml) fehlt. Bitte im Image installieren.", flush=True)
    sys.exit(2)

DEF_FALLBACKS = [
    "/etc/gluster/volumes.yml",
    "/etc/gluster/volumes.yaml",
    "/etc/glusterfs/volumes.yml",
    "/etc/glusterfs/volumes.yaml",
]


def detect_brick_host():
    """Choose a host/IP for brick specs (Gluster requires <host>:<abs-path>).
    Priority: $BRICK_HOST > $BIND_ADDR > hostname -f > hostname > 'localhost'.
    """
    for key in ("BRICK_HOST", "BIND_ADDR"):
        v = os.environ.get(key, "").strip()
        if v:
            return v
    try:
        res = run("hostname -f", check=False)
        if res.stdout.strip():
            return res.stdout.strip()
    except Exception:
        pass
    res = run("hostname", check=False)
    return (res.stdout or "").strip() or "localhost"
def log(*a): 
    print("[solo]", *a, flush=True)

def die(msg, code=1): 
    log("FATAL:", msg)
    sys.exit(code)

def run(cmd, check=True, capture=True):
    log("RUN:", cmd)
    res = subprocess.run(shlex.split(cmd), capture_output=capture, text=True)
    if check and res.returncode != 0:
        if capture:
            if res.stdout:
                log("STDOUT:", res.stdout.strip())
            if res.stderr:
                log("STDERR:", res.stderr.strip())
        die(f"cmd failed: {cmd} (rc={res.returncode})")
    return res

def find_yaml():
    cand = os.environ.get("VOLUMES_YAML")
    if cand and Path(cand).is_file():
        return Path(cand)
    for p in DEF_FALLBACKS:
        pp = Path(p)
        try:
            if pp.is_file() and pp.stat().st_size > 0:
                return pp
        except FileNotFoundError:
            continue
    return None

def load_spec(path: Path):
    try:
        with path.open("r", encoding="utf-8") as f:
            data = yaml.safe_load(f) or {}
    except Exception as e:
        die(f"YAML-Fehler in {path}: {e}")
    vols = data.get("volumes")
    if not isinstance(vols, list) or not vols:
        die(f"Ungültige/Leere YAML: {path}")
    for v in vols:
        if not isinstance(v, dict) or "name" not in v:
            die(f"Volume ohne 'name': {v}")
    return vols

def parse_bricks(replica: int):
    env = os.environ.get("BRICKS", "").strip()
    if env:
        bricks = [Path(p) for p in env.split() if p.strip()]
    else:
        bricks = [Path(f"/bricks/brick{i}") for i in range(1, int(replica)+1)]
    return bricks

def ensure_dirs(dirs):
    for d in dirs:
        try:
            d.mkdir(parents=True, exist_ok=True)
        except Exception as e:
            die(f"Konnte Verzeichnis nicht anlegen: {d} ({e})")
        if not os.access(d, os.W_OK):
            die(f"Brick-Verzeichnis nicht beschreibbar: {d}")

def volume_exists(name: str) -> bool:
    res = run(f"gluster --mode=script volume info {shlex.quote(name)}", check=False)
    return res.returncode == 0 and f"Volume Name: {name}" in (res.stdout or "")

def volume_status_started(name: str) -> bool:
    res = run(f"gluster --mode=script volume status {shlex.quote(name)}", check=False)
    return res.returncode == 0 and "Status of volume" in (res.stdout or "")

def gluster_create(name: str, replica: int, transport: str, bricks):
    host = detect_brick_host()
    brick_specs = [f"{host}:{str(p)}" for p in bricks]
    log(f"Brick host for volume '{name}': {host}")
    log("Bricks:", ", ".join(brick_specs))
    brick_args = " ".join(shlex.quote(b) for b in brick_specs)
    cmd = f"gluster volume create {shlex.quote(name)} replica {int(replica)} transport {transport} {brick_args} force"
    try:
        run(cmd)
    except SystemExit as e:
        # Enrich common error diagnostics
        # Re-run without --mode=script info to collect context
        hint = []
        hint.append("Fehlschlag beim Erstellen des Volumes.")
        hint.append(f"Verwendete Brick-Spezifikationen: {', '.join(brick_specs)}")
        hint.append("Hinweise:")
        hint.append("  - Gluster erwartet das Format <HOST>:<ABSOLUTER_PFAD> pro Brick.")
        hint.append("  - Host sollte der von glusterd bekannte Name/IP sein (siehe 'gluster peer status').")
        hint.append("  - Setze ggf. BRICK_HOST oder BIND_ADDR um den Host zu erzwingen.")
        die("\n".join(hint), code=e.code if isinstance(e.code, int) else 1)

def gluster_start(name: str):
    run(f"gluster volume start {shlex.quote(name)}", check=False)

def gluster_set_option(name: str, key: str, val: str):
    run(f"gluster volume set {shlex.quote(name)} {shlex.quote(key)} {shlex.quote(val)}")

def gluster_reset_option(name: str, key: str):
    run(f"gluster volume reset {shlex.quote(name)} {shlex.quote(key)}")

def apply_spec(vol):
    name = str(vol["name"])
    replica = int(vol.get("replica", os.environ.get("REPLICA", 1)))
    transport = (vol.get("transport") or os.environ.get("TRANSPORT") or "tcp").lower()

    # Brick-Wurzeln ermitteln und sicherstellen
    brick_roots = parse_bricks(replica)
    ensure_dirs(brick_roots)

    # Volumen-spezifische Brick-Pfade
    volume_bricks = [ (p / name).resolve() for p in brick_roots ]
    ensure_dirs(volume_bricks)

    # Erstellen, falls nicht vorhanden
    if not volume_exists(name):
        gluster_create(name, replica, transport, volume_bricks)

    # Optionen anwenden (idempotent)
    if "auth_allow" in vol:
        aa = vol["auth_allow"]
        if aa == "" or aa is None:
            gluster_reset_option(name, "auth.allow")
        else:
            gluster_set_option(name, "auth.allow", str(aa))

    if "nfs_disable" in vol:
        nfs_val = "on" if bool(vol["nfs_disable"]) else "off"
        gluster_set_option(name, "nfs.disable", nfs_val)

    opts = vol.get("options") or {}
    if isinstance(opts, dict):
        for k, v in opts.items():
            gluster_set_option(name, str(k), str(v))

    opts_reset = vol.get("options_reset")
    if isinstance(opts_reset, str):
        opts_reset = [x.strip() for x in opts_reset.split(",") if x.strip()]
    if isinstance(opts_reset, list):
        for k in opts_reset:
            gluster_reset_option(name, str(k))

    quota = vol.get("quota") or {}
    if isinstance(quota, dict) and quota.get("limit"):
        run(f"gluster volume quota {shlex.quote(name)} enable", check=False)
        run(f"gluster volume quota {shlex.quote(name)} limit-usage / {shlex.quote(str(quota['limit']))}", check=False)
        if quota.get("soft_limit_pct"):
            gluster_set_option(name, "features.soft-limit", str(int(quota["soft_limit_pct"])))

    # Start, wenn nicht gestartet
    if not volume_status_started(name):
        gluster_start(name)

def main():
    # Preflight diagnostics
    host = detect_brick_host()
    log(f"Detected brick host: {host}")
    path = find_yaml()
    if not path:
        log("Keine volumes.yml gefunden – nichts zu tun.")
        return
    log(f"YAML: {path}")
    vols = load_spec(path)
    for vol in vols:
        apply_spec(vol)
    log("Solo-Startup erfolgreich (idempotent).")

if __name__ == "__main__":
    main()
