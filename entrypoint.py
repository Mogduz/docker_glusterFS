#!/usr/bin/env python3
"""GlusterFS hybrid container entrypoint.

Roles:
- server: runs glusterd and keeps it in the foreground.
- server+bootstrap: additionally probes peers and creates the volume idempotently.
- client: performs FUSE mounts defined in the YAML config and keeps them alive; unmounts on shutdown.
- noop: does nothing (useful for testing the image).

Configuration is read from CONFIG_PATH (default: /etc/gluster-container/config.yaml).
This script aims to be idempotent and safe to restart.
"""
import os, sys, time, subprocess, yaml, signal, atexit, threading

CONFIG_PATH_DEFAULT = "/etc/gluster-container/config.yaml"
stop_event = threading.Event()

def log(msg):
    """Lightweight logger that prints a message with flush=True."""
    print(msg, flush=True)

def sh(cmd, check=True, capture=False):
    """Run a shell command. Optionally capture output and raise on non-zero exit if check=True."""
    if capture:
        p = subprocess.run(cmd, shell=True, text=True, capture_output=True)
    else:
        p = subprocess.run(cmd, shell=True)
    if check and p.returncode != 0:
        out = p.stdout if capture else ""
        err = p.stderr if capture else ""
        log(f"[ERR] {cmd}\n{out}\n{err}")
        raise SystemExit(p.returncode)
    return p

def is_mounted(path):
    """Function logic; see inline comments for details."""
    return subprocess.run(f"mountpoint -q {path}", shell=True).returncode == 0

def start_glusterd_foreground():
    """Function logic; see inline comments for details."""
    # Start glusterd in foreground (-N) so tini can manage it  # run glusterd in the foreground so Docker can supervise it
    return subprocess.Popen(["/usr/sbin/glusterd","-N"], stdout=sys.stdout, stderr=sys.stderr)  # run glusterd in the foreground so Docker can supervise it

def wait_glusterd(timeout=60):
    """Function logic; see inline comments for details."""
    # Wait until gluster CLI works
    for _ in range(timeout):
        if subprocess.run("gluster --version", shell=True).returncode == 0:
            return True
        time.sleep(1)
    return False

def cluster_init(volume_cfg):
    """Idempotently probe peers and create the Gluster volume using the provided config."""
    # Probe peers based on hostnames extracted from brick definitions
    bricks = volume_cfg.get("bricks") or []
    hosts = sorted({b.split(":")[0] for b in bricks if ":" in b})
    for h in hosts:
        sh(f"gluster peer probe {h}", check=False)
    time.sleep(2)
    name = volume_cfg["name"]
    exists = subprocess.run(f"gluster volume info {name}",
                            shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
    if not exists:
        vtype = volume_cfg.get("type","replica")
        transport = volume_cfg.get("transport","tcp")
        br = " ".join(bricks)
        if vtype == "replica":
            rep = int(volume_cfg.get("replica", 1))
            arb = int(volume_cfg.get("arbiter", 0))
            arb_str = f" arbiter {arb}" if arb else ""
            cmd = f"gluster volume create {name} replica {rep}{arb_str} transport {transport} {br} force"
        elif vtype == "disperse":
            data = int(volume_cfg.get("data",0))
            redundancy = int(volume_cfg.get("redundancy",0))
            opt = ""
            if data: opt += f" disperse-data {data}"
            if redundancy: opt += f" redundancy {redundancy}"
            cmd = f"gluster volume create {name}{opt} transport {transport} {br} force"
        else:
            # distribute or other simple types
            cmd = f"gluster volume create {name} transport {transport} {br} force"
        log(f"[INFO] Creating volume: {cmd}")
        sh(cmd)
        sh(f"gluster volume start {name}")
    # Set options (idempotent)
    for k, v in (volume_cfg.get("options") or {}).items():
        sh(f"gluster volume set {name} {k} {v}", check=False)
    log(f"[INFO] Volume '{name}' ready.")

def do_mount(remote, target, opts=""):
    """Mount a GlusterFS volume (remote) to the given target with optional mount options."""
    os.makedirs(target, exist_ok=True)
    if not is_mounted(target):
        opt = f"-o {opts} " if (opts or "").strip() else ""
        cmd = f"mount -t glusterfs  # FUSE mount of Gluster volume {opt}{remote} {target}"
        log(f"[INFO] Mounting: {cmd}")
        sh(cmd)
        log(f"[INFO] Mounted {remote} -> {target}")
    else:
        log(f"[INFO] Already mounted: {target}")

def do_umount(target):
    """Attempt to unmount the given target path; ignore errors if already unmounted."""
    if is_mounted(target):
        if subprocess.run(f"umount {target}", shell=True).returncode != 0:
            subprocess.run(f"umount -l {target}", shell=True)
        log(f"[INFO] Unmounted {target}")

def server_loop():
    """Background loop to periodically emit cluster status while the server runs."""
    # Emit lightweight status every 60s
    while not stop_event.wait(60):
        subprocess.run("gluster peer status", shell=True)

def client_mode(cfg):
    """Handle client role: perform mounts defined in config and block until signalled to stop."""
    mounts = cfg.get("mounts") or []
    # Perform mounts
    for m in mounts:
        remote = m["remote"]
        target = m["target"]
        opts = m.get("opts","")
        os.makedirs(target, exist_ok=True)
        do_mount(remote, target, opts)
        # ensure unmount at exit
        atexit.register(lambda t=target: do_umount(t))
    # Block until stop
    log("[INFO] Client running. Waiting for SIGTERM/SIGINT to unmount...")
    while not stop_event.wait(1):
        pass

def handle_signal(signum, frame):
    """Signal handler that sets a stop event for graceful shutdown."""
    stop_event.set()

def main():
    """Program entrypoint: parse config, dispatch by role, and block appropriately."""
    cfg_path = os.environ.get("CONFIG_PATH", None) or (sys.argv[1] if len(sys.argv) > 1 else CONFIG_PATH_DEFAULT)
    cfg = {}
    if os.path.exists(cfg_path):
        with open(cfg_path) as f:
            cfg = yaml.safe_load(f) or {}
    role = (cfg.get("role") or os.environ.get("ROLE") or "server").lower()

    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)

    if role in ("client",):
        log("[INFO] Role: client")
        client_mode(cfg)
        return
    elif role in ("noop",):
        log("[INFO] Role: noop (no daemons). Sleeping.")
        while not stop_event.wait(3600):
            pass
        return
    # server roles
    log("[INFO] Role: " + role)
    proc = start_glusterd_foreground()
    try:
        if not wait_glusterd():
            log("[ERR] glusterd did not become ready in time")
            raise SystemExit(1)
        if role == "server+bootstrap" and "volume" in cfg:
            log("[INFO] Bootstrap: checking/creating volume ...")
            cluster_init(cfg["volume"])
        # background status loop
        t = threading.Thread(target=server_loop, daemon=True)
        t.start()
        # wait until stop
        while not stop_event.wait(1):
            pass
    finally:
        try:
            proc.terminate()
            proc.wait(timeout=10)
        except Exception:
            pass
        log("[INFO] Server stopped.")

if __name__ == "__main__":
    main()