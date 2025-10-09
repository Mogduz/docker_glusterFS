#!/usr/bin/env python3
"""
GlusterFS hybrid container entrypoint (diagnostisch, robust gegenüber glusterd-Flag-Varianten).

Rollen: server | server+bootstrap | client | noop
Siehe README im Dockerfile. Dieses Skript erzeugt ausführliche Logs und bricht mit
sinnvollen Exit-Codes + Ursachenbeschreibung ab.
"""
from __future__ import annotations

import argparse
import atexit
import os
import signal
import subprocess
import sys
import threading
import time
from datetime import datetime, timezone

try:
    import yaml
except Exception as e:
    print("FATAL: python3-yaml nicht installiert? %r" % (e,), file=sys.stderr)
    sys.exit(90)

CONFIG_PATH_DEFAULT = "/etc/gluster-container/config.yaml"

# ----------------------------- Logging -----------------------------
LEVELS = {"DEBUG": 10, "INFO": 20, "WARN": 30, "ERROR": 40}
LOG_LEVEL = LEVELS.get(os.environ.get("LOG_LEVEL", "INFO").upper(), 20)
LOG_FORMAT = os.environ.get("LOG_FORMAT", "text").lower()
DRY_RUN = os.environ.get("DRY_RUN", "0") in ("1", "true", "yes", "on")

stop_event = threading.Event()
child_procs = []  # type: list[subprocess.Popen]

def _ts() -> str:
    # timezone-aware UTC (vermeidet DeprecationWarning)
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")

def log(level: str, msg: str, **fields):
    lv = LEVELS.get(level.upper(), 20)
    if lv < LOG_LEVEL:
        return
    if LOG_FORMAT == "json":
        import json
        obj = {"ts": _ts(), "level": level.upper(), "msg": msg}
        if fields:
            obj.update(fields)
        print(json.dumps(obj, ensure_ascii=False), file=sys.stderr)
    else:
        parts = [f"{_ts()} [{level.upper()}] {msg}"]
        for k, v in fields.items():
            parts.append(f"{k}={v}")
        print(" ".join(parts), file=sys.stderr)

def die(exitcode: int, msg: str, **fields):
    log("ERROR", msg, **fields)
    sys.exit(exitcode)

# ----------------------------- Shell helpers -----------------------------
def which(cmd: str) -> str | None:
    for p in os.environ.get("PATH", "").split(os.pathsep):
        cand = os.path.join(p, cmd)
        if os.path.isfile(cand) and os.access(cand, os.X_OK):
            return cand
    return None

def require(cmd: str):
    if not which(cmd):
        die(10, f"Benötigtes Kommando nicht gefunden: {cmd}")

def run(cmd: str, check: bool = True, timeout: int | None = None) -> subprocess.CompletedProcess:
    """Run a shell command, capture output, and always log failures verbosely."""
    if DRY_RUN:
        log("INFO", "DRY_RUN: würde ausführen", cmd=cmd)
        return subprocess.CompletedProcess(cmd, 0, "", "")
    log("DEBUG", "exec", cmd=cmd)
    cp = subprocess.run(cmd, shell=True, text=True, capture_output=True, timeout=timeout)
    if check and cp.returncode != 0:
        log("ERROR", "Kommando fehlgeschlagen", cmd=cmd, rc=cp.returncode, stderr=(cp.stderr or "").strip(), stdout=(cp.stdout or "").strip())
        raise subprocess.CalledProcessError(cp.returncode, cmd, output=cp.stdout, stderr=cp.stderr)
    return cp

def is_mounted(target: str) -> bool:
    cp = subprocess.run(f"mountpoint -q '{target.replace("'", "'\\''")}'", shell=True)
    return cp.returncode == 0

def ensure_dir(path: str):
    os.makedirs(path, exist_ok=True)

# ----------------------------- YAML config -----------------------------
def load_config(path: str) -> dict:
    if not os.path.isfile(path):
        die(20, "Konfigurationsdatei nicht gefunden", path=path)
    try:
        with open(path, "r", encoding="utf-8") as f:
            cfg = yaml.safe_load(f) or {}
        if not isinstance(cfg, dict):
            die(21, "Ungültiges YAML-Format: Top-Level ist kein Mapping", path=path)
        return cfg
    except Exception as e:
        die(22, "Konnte YAML nicht lesen", path=path, error=repr(e))

# ----------------------------- Role logic -----------------------------
def _spawn(cmd: str) -> subprocess.Popen:
    """Starte einen Prozess, leite stdout/stderr zum Container-Log um (kein capture)."""
    if DRY_RUN:
        log("INFO", "DRY_RUN: würde Prozess starten", cmd=cmd)
        return subprocess.Popen(["/bin/sh", "-c", "sleep 3600"])
    log("INFO", "Starte Prozess", cmd=cmd)
    p = subprocess.Popen(cmd, shell=True, text=True)
    child_procs.append(p)
    return p

def start_glusterd() -> subprocess.Popen:
    """Robustes Starten: versuche -N, dann --no-daemon, dann ohne Flag. Logge --help bei Fehler."""
    require("glusterd")
    candidates = ["glusterd -N", "glusterd --no-daemon", "glusterd"]
    last_err = None
    for cmd in candidates:
        p = _spawn(cmd)
        # Wenn der Prozess sofort stirbt, probiere die nächste Variante
        time.sleep(1.0)
        if p.poll() is None:
            log("INFO", "glusterd läuft", cmd=cmd, pid=p.pid)
            return p
        else:
            rc = p.returncode
            try:
                help_out = subprocess.run("glusterd --help", shell=True, text=True, capture_output=True)
                log("WARN", "glusterd Variante fehlgeschlagen", cmd=cmd, rc=rc, help=(help_out.stdout or help_out.stderr or "").splitlines()[:5])
            except Exception:
                log("WARN", "glusterd Variante fehlgeschlagen (kein --help verfügbar?)", cmd=cmd, rc=rc)
            last_err = rc
    die(29, "Alle Startvarianten für glusterd sind fehlgeschlagen", last_rc=last_err)

def wait_glusterd_ready(proc: subprocess.Popen, timeout_sec: int = 45):
    require("gluster")
    start = time.time()
    while time.time() - start < timeout_sec:
        if proc.poll() is not None:
            die(31, "glusterd hat unerwartet beendet", rc=proc.returncode)
        cp = subprocess.run("gluster volume list >/dev/null 2>&1 || gluster peer status >/dev/null 2>&1", shell=True)
        if cp.returncode == 0:
            log("INFO", "glusterd bereit")
            return
        time.sleep(1)
    die(30, "glusterd wurde nicht innerhalb des Zeitlimits bereit")

def bootstrap_server(cfg: dict):
    peers = cfg.get("peers") or []
    volume = (cfg.get("volume") or {})

    for host in peers:
        if not host:
            continue
        try:
            run(f"gluster peer probe {host}", check=False)  # idempotent
        except Exception:
            log("WARN", "Peer-Probe fehlgeschlagen", host=host)

    name = volume.get("name")
    bricks = volume.get("bricks") or []
    vtype = (volume.get("type") or "").lower()
    transport = volume.get("transport", "tcp")
    replica = volume.get("replica")
    arbiter = volume.get("arbiter")
    disperse = volume.get("disperse")
    redundancy = volume.get("redundancy")

    if name and bricks:
        br = " ".join(bricks)
        if vtype in ("replicate", "distributed-replicate", "dist-replicate"):
            opt = f" replica {int(replica) if replica else 2}"
            if arbiter is not None:
                opt += f" arbiter {int(arbiter)}"
            cmd = f"gluster volume create {name}{opt} transport {transport} {br} force"
        elif vtype in ("disperse", "distributed-disperse", "dist-disperse"):
            opt = f" disperse {int(disperse) if disperse else 4}"
            if redundancy is not None:
                opt += f" redundancy {int(redundancy)}"
            cmd = f"gluster volume create {name}{opt} transport {transport} {br} force"
        else:
            cmd = f"gluster volume create {name} transport {transport} {br} force"
        log("INFO", "Erzeuge Volume (idempotent)", cmd=cmd)
        run(cmd, check=False)
        run(f"gluster volume start {name}", check=False)
        for k, v in (volume.get("options") or {}).items():
            run(f"gluster volume set {name} {k} {v}", check=False)
        log("INFO", "Volume bereit", name=name)
    else:
        log("INFO", "Kein Volume-Bootstrap konfiguriert (name/bricks fehlen)")

def client_mounts(cfg: dict):
    mounts = cfg.get("mounts") or []
    if not mounts:
        log("WARN", "Keine Mounts im client-Modus konfiguriert")
    for m in mounts:
        remote = m.get("remote")
        target = m.get("target") or "/mnt/gluster"
        opts = m.get("opts") or ""
        if not remote:
            log("ERROR", "Mount-Eintrag ohne 'remote'", target=target)
            continue
        ensure_dir(target)
        if is_mounted(target):
            log("INFO", "Bereits gemountet", target=target)
            continue
        cmd = f"mount -t glusterfs {remote} '{target.replace("'", "'\\''")}'"
        if opts.strip():
            cmd = f"mount -t glusterfs -o {opts} {remote} '{target.replace("'", "'\\''")}'"
        try:
            run(cmd, check=True)
            log("INFO", "Gemountet", remote=remote, target=target)
        except subprocess.CalledProcessError as e:
            die(41, "Mount fehlgeschlagen", remote=remote, target=target, rc=e.returncode)

def client_unmounts(cfg: dict):
    mounts = cfg.get("mounts") or []
    for m in mounts:
        target = m.get("target") or "/mnt/gluster"
        if is_mounted(target):
            log("INFO", "Unmount", target=target)
            run(f"umount '{target.replace("'", "'\\''")}' || umount -l '{target.replace("'", "'\\''")}'", check=False)

def _handle_stop(signum, frame):
    log("INFO", "Signal empfangen, stoppe...", signal=signum)
    stop_event.set()

for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
    signal.signal(sig, _handle_stop)

def _kill_children():
    for p in child_procs:
        try:
            if p.poll() is None:
                log("INFO", "Beende Kindprozess", pid=p.pid)
                p.terminate()
                try:
                    p.wait(timeout=10)
                except Exception:
                    p.kill()
        except Exception:
            pass

atexit.register(_kill_children)

def main():
    parser = argparse.ArgumentParser(description="GlusterFS Container Entrypoint (diagnostisch)")
    parser.add_argument("config", nargs="?", default=os.environ.get("CONFIG_PATH", CONFIG_PATH_DEFAULT),
                        help="Pfad zur YAML-Konfiguration (default: %(default)s)")
    parser.add_argument("--role", default=os.environ.get("ROLE", "").strip(),
                        help="Rolle überschreiben: server | server+bootstrap | client | noop")
    parser.add_argument("--dry-run", action="store_true", help="Nur loggen, keine Kommandos ausführen")
    parser.add_argument("--log-format", choices=["text", "json"], default=os.environ.get("LOG_FORMAT", "text"),
                        help="Logformat (text/json)")
    parser.add_argument("--log-level", choices=["DEBUG","INFO","WARN","ERROR"], default=os.environ.get("LOG_LEVEL","INFO"),
                        help="Loglevel")
    args = parser.parse_args()

    global LOG_FORMAT, LOG_LEVEL, DRY_RUN
    LOG_FORMAT = args.log_format
    LOG_LEVEL = LEVELS[args.log_level]
    if args.dry_run:
        DRY_RUN = True

    cfg = load_config(args.config)
    role = (args.role or cfg.get("role") or "noop").lower()

    log("INFO", "Starte Entrypoint", role=role, config=args.config, dry_run=DRY_RUN)

    if role == "noop":
        while not stop_event.wait(1):
            pass
        log("INFO", "noop beendet")
        return

    if role.startswith("server"):
        proc = start_glusterd()
        try:
            wait_glusterd_ready(proc)
            if role == "server+bootstrap":
                bootstrap_server(cfg)
            while not stop_event.wait(1):
                if proc.poll() is not None:
                    die(31, "glusterd hat unerwartet beendet", rc=proc.returncode)
            log("INFO", "Stoppe server...")
        finally:
            try:
                proc.terminate()
                proc.wait(timeout=10)
            except Exception:
                pass
            log("INFO", "Server gestoppt")
        return

    if role == "client":
        try:
            client_mounts(cfg)
            while not stop_event.wait(1):
                pass
        finally:
            log("INFO", "Unmounts (client)")
            client_unmounts(cfg)
        return

    die(2, "Unbekannte Rolle", role=role)

if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as e:
        die(50, "Kritischer Shellfehler", cmd=e.cmd, rc=e.returncode)
    except KeyboardInterrupt:
        die(130, "Abgebrochen (SIGINT)")
    except SystemExit:
        raise
    except Exception as e:
        die(99, "Unerwarteter Fehler", error=repr(e))
