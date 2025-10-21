#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import argparse, json, os, re, shlex, subprocess, sys, time
from datetime import datetime
from pathlib import Path

try:
    import yaml  # PyYAML
except Exception:
    print("[solo] FATAL: PyYAML fehlt (python3-yaml).", flush=True)
    sys.exit(2)

# -------------------------
# Konfiguration + Defaults
# -------------------------
DEF_FALLBACKS = [
    "/etc/gluster/volumes.yml",
    "/etc/gluster/volumes.yaml",
    "/etc/glusterfs/volumes.yml",
    "/etc/glusterfs/volumes.yaml",
]

INTERESTING_ENVS = [
    "VOLUMES_YAML", "BRICKS", "REPLICA", "TRANSPORT", "BRICK_HOST", "BIND_ADDR",
    "SOLO_LOG_FORMAT", "SOLO_LOG_LEVEL", "SOLO_DRY_RUN", "SOLO_REPORT",
]

# -------------------------
# Logging
# -------------------------
LEVELS = {"TRACE": 5, "DEBUG": 10, "INFO": 20, "WARN": 30, "ERROR": 40}
LOG_LEVEL = LEVELS.get(os.environ.get("SOLO_LOG_LEVEL", "INFO").upper(), 20)
LOG_FMT = os.environ.get("SOLO_LOG_FORMAT", "text").lower()  # text|json

def _now_iso():
    return datetime.utcnow().isoformat(timespec="milliseconds") + "Z"

def _emit(level, event, **kv):
    if LEVELS[level] < LOG_LEVEL:
        return
    record = dict(ts=_now_iso(), level=level, event=event, **kv)
    if LOG_FMT == "json":
        print(json.dumps(record, ensure_ascii=False), flush=True)
    else:
        ctx = " ".join(f"{k}={json.dumps(v, ensure_ascii=False)}" for k,v in kv.items())
        print(f"[solo] {record['ts']} {level:<5} {event} {ctx}".rstrip(), flush=True)

def log_debug(event, **kv): _emit("DEBUG", event, **kv)
def log_trace(event, **kv): _emit("TRACE", event, **kv)
def log_info(event, **kv):  _emit("INFO",  event, **kv)
def log_warn(event, **kv):  _emit("WARN",  event, **kv)
def log_error(event, **kv): _emit("ERROR", event, **kv)

class Span:
    def __init__(self, name, **kv):
        self.name = name
        self.kv = kv
    def __enter__(self):
        self.t0 = time.perf_counter()
        log_debug(f"{self.name}.begin", **self.kv)
        return self
    def __exit__(self, exc_type, exc, tb):
        dt = time.perf_counter() - self.t0
        if exc is None:
            log_info(f"{self.name}.end", duration_ms=int(dt*1000), **self.kv)
        else:
            log_error(f"{self.name}.error", duration_ms=int(dt*1000), err=str(exc), **self.kv)

# -------------------------
# Shell-Helfer
# -------------------------
def run(cmd, check=True, capture=True, env=None):
    """
    Führt einen Shell-Befehl aus, loggt Start, Dauer, Exitcode, ggf. Ausschnitte von STDOUT/STDERR.
    """
    if isinstance(cmd, str): shell_cmd = cmd
    else: shell_cmd = " ".join(shlex.quote(str(x)) for x in cmd)

    with Span("run", cmd=shell_cmd):
        proc = subprocess.run(
            shell_cmd, shell=True, capture_output=capture, text=True, env=env
        )
        out = (proc.stdout or "")
        err = (proc.stderr or "")
        log_trace("run.stdout", cmd=shell_cmd, bytes=len(out), preview=out[:4000])
        if err.strip():
            log_trace("run.stderr", cmd=shell_cmd, bytes=len(err), preview=err[:4000])
        log_debug("run.result", cmd=shell_cmd, rc=proc.returncode)
        if check and proc.returncode != 0:
            raise RuntimeError(f"cmd failed rc={proc.returncode}: {shell_cmd}\n{err}")
        return proc

# -------------------------
# Utilities
# -------------------------
def host_seems_local(host: str) -> bool:
    host = (host or "").strip().lower()
    if host in ("127.0.0.1","localhost"): return True
    try:
        res = run("hostname -I", check=False)
        ips = (res.stdout or "").split()
        return host in ips
    except Exception:
        return False

def pick_local_brick_host():
    host = os.environ.get("BRICK_HOST") or os.environ.get("BIND_ADDR") or ""
    if host and host_seems_local(host):
        log_info("brick_host.ok", brick_host=host)
        return host
    ba = os.environ.get("BIND_ADDR", "")
    if ba and host_seems_local(ba):
        os.environ["BRICK_HOST"] = ba
        log_warn("brick_host.corrected", from_value=host or None, to_value=ba, reason="BIND_ADDR local")
        return ba
    res = run("hostname -I", check=False)
    ips = (res.stdout or "").split()
    new = ips[0] if ips else "127.0.0.1"
    os.environ["BRICK_HOST"] = new
    log_warn("brick_host.corrected", from_value=host or None, to_value=new, reason="first_local_ip_or_loopback")
    return new

def ensure_dir(p: Path):
    p.mkdir(parents=True, exist_ok=True)
    st = p.stat()
    log_debug("dir.ensure", path=str(p), mode=octx(st.st_mode), uid=st.st_uid, gid=st.st_gid)

def octx(mode):
    return oct(mode & 0o777)

def parse_bricks(replica: int):
    env = (os.environ.get("BRICKS") or "").strip()
    if env:
        bricks = [Path(x).resolve() for x in env.split() if x.strip()]
    else:
        bricks = [Path(f"/bricks/brick{i+1}").resolve() for i in range(replica)]
    log_info("bricks.parse", source="ENV" if env else "default", count=len(bricks), bricks=[str(b) for b in bricks])
    return bricks

def volume_exists(name: str) -> bool:
    res = run(f"gluster --mode=script volume info {shlex.quote(name)}", check=False)
    present = f"Volume Name: {name}" in (res.stdout or "")
    log_debug("volume.exists", name=name, exists=present)
    return present

def volume_running(name: str) -> bool:
    res = run(f"gluster --mode=script volume status {shlex.quote(name)}", check=False)
    up = "Status of volume: " in (res.stdout or "") and "NFS Server" in (res.stdout or "") or "Status of volume" in (res.stdout or "")
    log_debug("volume.running", name=name, running=bool(up))
    return bool(up)

def gluster_ready(timeout=30):
    t0 = time.time()
    last_err = None
    while time.time() - t0 < timeout:
        try:
            res = run("gluster --mode=script volume list", check=False)
            if res.returncode == 0:
                return True
            last_err = res.stderr
        except Exception as e:
            last_err = str(e)
        time.sleep(1)
    log_error("gluster.ready_timeout", timeout_s=timeout, last_error=last_err)
    return False

def gluster_create(name, replica, transport, volume_bricks, dry=False):
    host = pick_local_brick_host()
    brick_specs = [f"{host}:{p}" for p in volume_bricks]
    cmd = ["gluster","volume","create", name, "replica", str(replica), "transport", transport, *brick_specs, "force"]
    if dry:
        log_info("gluster.create.dry_run", name=name, cmd=" ".join(shlex.quote(c) for c in cmd))
        return
    run(cmd)
    log_info("gluster.create", name=name, replica=replica, transport=transport, bricks=brick_specs)

def set_options(name, options: dict, dry=False):
    for k, v in (options or {}).items():
        cmd = f"gluster volume set {shlex.quote(name)} {shlex.quote(str(k))} {shlex.quote(str(v))}"
        if dry:
            log_info("gluster.set.dry_run", name=name, key=k, value=v, cmd=cmd)
        else:
            run(cmd)
            log_info("gluster.set", name=name, key=k, value=v)

def reset_options(name, keys, dry=False):
    if not keys: return
    if isinstance(keys, str):
        keys = [x.strip() for x in keys.split(",") if x.strip()]
    for k in keys:
        cmd = f"gluster volume reset {shlex.quote(name)} {shlex.quote(str(k))}"
        if dry:
            log_info("gluster.reset.dry_run", name=name, key=k, cmd=cmd)
        else:
            run(cmd)
            log_info("gluster.reset", name=name, key=k)

def configure_quota(name, quota: dict, dry=False):
    if not quota: return
    limit = quota.get("limit")
    if not limit: return
    if dry:
        log_info("gluster.quota.dry_run", name=name, limit=limit, soft_limit_pct=quota.get("soft_limit_pct"))
        return
    run(f"gluster volume quota {shlex.quote(name)} enable", check=False)
    run(f"gluster volume quota {shlex.quote(name)} limit-usage / {shlex.quote(str(limit))}")
    sl = quota.get("soft_limit_pct")
    if sl is not None:
        pct = str(sl).strip()
        if pct.endswith("%"): pct = pct[:-1]
        if not pct.isdigit():
            raise SystemExit(f"Ungültige soft_limit_pct: {sl}")
        run(f"gluster volume quota {shlex.quote(name)} default-soft-limit {shlex.quote(pct)}")
    log_info("gluster.quota", name=name, limit=limit, soft_limit_pct=quota.get("soft_limit_pct"))

def load_spec(path: Path):
    with Span("yaml.load", path=str(path)):
        spec = yaml.safe_load(path.read_text(encoding="utf-8"))
        if not spec or "volumes" not in spec or not isinstance(spec["volumes"], list):
            raise SystemExit("YAML muss eine Liste unter 'volumes' enthalten.")
        return spec

def find_yaml(cli_path: str | None):
    if cli_path:
        p = Path(cli_path)
        return p if p.exists() else None
    env = os.environ.get("VOLUMES_YAML")
    if env:
        p = Path(env)
        return p if p.exists() else None
    for fp in DEF_FALLBACKS:
        p = Path(fp)
        if p.exists(): return p
    return None

# -------------------------
# Main
# -------------------------
def main():
    ap = argparse.ArgumentParser(description="Gluster Solo-Startup (gesprächig).")
    ap.add_argument("--volumes-yaml", default=None, help="Pfad zur volumes.yml (übersteuert ENV)")
    ap.add_argument("--dry-run", action="store_true", help="Nur loggen, nichts ausführen")
    ap.add_argument("--log-format", choices=["text","json"], default=os.environ.get("SOLO_LOG_FORMAT","text"))
    ap.add_argument("--log-level", choices=list(LEVELS), default=os.environ.get("SOLO_LOG_LEVEL","INFO"))
    ap.add_argument("--report", default=os.environ.get("SOLO_REPORT",""), help="JSON-Report-Datei schreiben")
    ap.add_argument("--gluster-timeout", type=int, default=int(os.environ.get("SOLO_GLUSTER_TIMEOUT","30")), help="Sekunden auf glusterd warten")
    args = ap.parse_args()

    # Update globale Log-Settings aus CLI
    global LOG_FMT, LOG_LEVEL
    LOG_FMT  = args.log_format
    LOG_LEVEL = LEVELS[args.log_level]

    # Intro + Umgebung
    log_info("startup.begin", version="2.0", pid=os.getpid())
    for k in INTERESTING_ENVS:
        if k in os.environ:
            log_debug("env", key=k, value=os.environ.get(k))

    # Preflight
    with Span("preflight"):
        # Versionen
        run("python3 --version", check=False)
        run("gluster --version", check=False)
        run("uname -a", check=False)
        if not gluster_ready(timeout=args.gluster_timeout):
            raise SystemExit("glusterd nicht erreichbar (Timeout).")

    # YAML finden & laden
    yaml_path = find_yaml(args.volumes_yaml)
    if not yaml_path:
        log_warn("yaml.not_found", tried=[args.volumes_yaml] if args.volumes_yaml else DEF_FALLBACKS, note="nichts zu tun")
        log_info("startup.end", result="noop")
        return

    spec = load_spec(yaml_path)
    vols = spec["volumes"]
    log_info("yaml.loaded", path=str(yaml_path), volumes=len(vols), names=[str(v.get("name")) for v in vols])

    # Ergebnis-Sammlung
    report = {"created":[], "started":[], "options_set":{}, "options_reset":{}, "quota":{}}

    for vol in vols:
        name = str(vol["name"])
        replica = int(vol.get("replica") or os.environ.get("REPLICA") or 1)
        transport = (vol.get("transport") or os.environ.get("TRANSPORT") or "tcp").lower()
        bricks_root = parse_bricks(replica)
        if len(bricks_root) < replica:
            raise SystemExit(f"BRICKS liefert {len(bricks_root)} Einträge, benötigt replica={replica}")

        # Brick-Verzeichnisse
        volume_bricks = [(p / name).resolve() for p in bricks_root]
        for p in bricks_root + volume_bricks:
            ensure_dir(p)

        # Create
        if not volume_exists(name):
            gluster_create(name, replica, transport, [str(p) for p in volume_bricks], dry=args.dry_run)
            report["created"].append(name)
        else:
            log_info("volume.already_exists", name=name)

        # Start
        if not volume_running(name):
            if args.dry_run:
                log_info("gluster.start.dry_run", name=name)
            else:
                run(f"gluster volume start {shlex.quote(name)}", check=False)
                log_info("gluster.start", name=name)
            report["started"].append(name)
        else:
            log_info("volume.already_running", name=name)

        # Optionen
        opts = vol.get("options") or {}
        if opts:
            set_options(name, opts, dry=args.dry_run)
            report["options_set"][name] = opts

        resets = vol.get("options_reset")
        if resets:
            reset_options(name, resets, dry=args.dry_run)
            report["options_reset"][name] = resets if isinstance(resets, list) else str(resets)

        # Quota
        quota = vol.get("quota")
        if quota and quota.get("limit"):
            configure_quota(name, quota, dry=args.dry_run)
            report["quota"][name] = quota

    # Abschluss
    if args.report:
        try:
            Path(args.report).write_text(json.dumps(report, indent=2, ensure_ascii=False))
            log_info("report.written", path=args.report)
        except Exception as e:
            log_warn("report.write_failed", path=args.report, err=str(e))
    log_info("startup.end", result="ok", summary=report)

if __name__ == "__main__":
    try:
        main()
    except SystemExit as e:
        log_error("startup.exit", code=int(e.code) if isinstance(e.code,int) else 1)
        raise
    except Exception as e:
        log_error("startup.unhandled", err=str(e))
        raise
