#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import os, sys, subprocess, shlex
from pathlib import Path
try:
    import yaml
except Exception:
    print("[solo] FATAL: PyYAML fehlt (python3-yaml).", flush=True)
    sys.exit(2)

DEF_FALLBACKS = ["/etc/gluster/volumes.yml","/etc/gluster/volumes.yaml","/etc/glusterfs/volumes.yml","/etc/glusterfs/volumes.yaml"]

def log(*a): print("[solo]", *a, flush=True)
def die(msg, code=1): log("FATAL:", msg); sys.exit(code)

def run(cmd, check=True, capture=True):
    res = subprocess.run(shlex.split(cmd), capture_output=capture, text=True)
    log("RUN:", cmd)
    if check and res.returncode != 0:
        if res.stdout: log("STDOUT:", res.stdout.strip())
        if res.stderr: log("STDERR:", res.stderr.strip())
        die(f"cmd failed: {cmd} (rc={res.returncode})", code=res.returncode)
    return res

def detect_brick_host():
    for key in ("BRICK_HOST","BIND_ADDR"):
        v = os.environ.get(key, "").strip()
        if v:
            return v
    return "127.0.0.1"


def pick_local_brick_host():
    """Wähle einen Brick-Host, den glusterd als lokal erkennt.
    Reihenfolge: bestehender BRICK_HOST -> BIND_ADDR -> erste IP aus `hostname -I` -> 127.0.0.1.
    Bei Korrekturen wird BRICK_HOST in der Umgebung gesetzt, damit Folge-Logs konsistent sind.
    """
    host = detect_brick_host()
    if host_seems_local(host):
        return host
    ba = os.environ.get("BIND_ADDR", "").strip()
    if ba and host_seems_local(ba):
        log(f"Korrigiere BRICK_HOST von '{host}' auf BIND_ADDR '{ba}'")
        os.environ["BRICK_HOST"] = ba
        return ba
    res = run("hostname -I", check=False)
    ips = (res.stdout or "").split()
    if ips:
        log(f"Korrigiere BRICK_HOST von '{host}' auf lokale IP '{ips[0]}'")
        os.environ["BRICK_HOST"] = ips[0]
        return ips[0]
    log(f"Korrigiere BRICK_HOST von '{host}' auf '127.0.0.1'")
    os.environ["BRICK_HOST"] = "127.0.0.1"
    return "127.0.0.1"

def host_seems_local(host: str) -> bool:
    if host in ("127.0.0.1","localhost"): return True
    res = run("hostname -I", check=False)
    ips = (res.stdout or "").split()
    return host in ips

def find_yaml():
    cand = os.environ.get("VOLUMES_YAML")
    if cand and Path(cand).is_file() and Path(cand).stat().st_size>0: return Path(cand)
    for p in DEF_FALLBACKS:
        pp = Path(p)
        if pp.is_file() and pp.stat().st_size>0: return pp
    return None

def load_spec(path: Path):
    try: data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    except Exception as e: die(f"YAML-Fehler in {path}: {e}")
    vols = data.get("volumes")
    if not isinstance(vols, list) or not vols: die(f"Ungültige/Leere YAML: {path}")
    for v in vols:
        if not isinstance(v, dict) or "name" not in v: die(f"Volume ohne 'name': {v}")
    return vols

def parse_bricks(replica: int):
    env = os.environ.get("BRICKS","").strip()
    if env: bricks = [Path(p).resolve() for p in env.split() if p.strip()]
    else:   bricks = [Path(f"/bricks/brick{i}").resolve() for i in range(1, int(replica)+1)]
    return bricks

def ensure_dirs(dirs):
    for d in dirs:
        try: d.mkdir(parents=True, exist_ok=True)
        except Exception as e: die(f"Konnte Verzeichnis nicht anlegen: {d} ({e})")
        if not os.access(d, os.W_OK): die(f"Brick-Verzeichnis nicht beschreibbar: {d}")


def preflight_xattr(path: Path):
    """
    Kurzer Selbsttest: Können wir trusted.*-xattrs am Brick setzen?
    Liefert im Fehlerfall einen klaren Hinweis (CAP_SYS_ADMIN / FS).
    """
    probe = (path / ".gluster-xattr-probe")
    try:
        probe.touch(exist_ok=True)
        # Versuch 1: Python-API (vermeidet Abhängigkeit von setfattr)
        try:
            os.setxattr(str(probe), "trusted.test", b"1")
        except AttributeError:
            # Fallback: setfattr CLI
            run(f"setfattr -n trusted.test -v 1 {shlex.quote(str(probe))}", check=True)
        except PermissionError:
            die(f"Extended Attributes (trusted.*) nicht setzbar auf {path}. "
                f"Ursache: fehlende Capability (CAP_SYS_ADMIN) oder ungeeignetes Dateisystem. "
                f"Maßnahme: 'cap_add: [SYS_ADMIN]' in Compose ergänzen und sicherstellen, dass {path} auf ext4/xfs (kein NFS/CIFS/Overlay) liegt.")
        # Clean up attribute best effort
        try:
            os.removexattr(str(probe), "trusted.test")
        except Exception:
            pass
    except SystemExit:
        # run(...) hat bereits geloggt; eskaliere mit klarer Botschaft
        die(f"Extended Attributes (trusted.*) nicht setzbar auf {path}. "
            f"Prüfe: cap_add: [SYS_ADMIN] in Compose und dass {path} auf ext4/xfs (kein NFS/CIFS/Overlay) liegt.")
    finally:
        try:
            probe.unlink()
        except Exception:
            pass


def _print_indented_output(res):
    out = (res.stdout or "").strip()
    err = (res.stderr or "").strip()
    if out:
        for line in out.splitlines():
            print(f"[solo]   {line}", flush=True)
    if err and res.returncode != 0:
        for line in err.splitlines():
            print(f"[solo]   (stderr) {line}", flush=True)

def volume_report(name: str):
    """Gibt am Stück eine kompakte Übersicht für das Volume aus (Info/Status/Quota)."""
    log(f"==== VOLUME REPORT: {name} ====")
    log("  [info]")
    _print_indented_output(run(f"gluster --mode=script volume info {shlex.quote(name)}", check=False))
    log("  [status]")
    _print_indented_output(run(f"gluster --mode=script volume status {shlex.quote(name)}", check=False))
    log("  [quota list]")
    _print_indented_output(run(f"gluster volume quota {shlex.quote(name)} list", check=False))
    log(f"==== END REPORT: {name} ====")
def volume_exists(name: str) -> bool:
    res = run(f"gluster --mode=script volume info {shlex.quote(name)}", check=False)
    return res.returncode == 0 and f"Volume Name: {name}" in (res.stdout or "")

def volume_running(name: str) -> bool:
    res = run(f"gluster --mode=script volume status {shlex.quote(name)}", check=False)
    return res.returncode == 0 and "Status of volume" in (res.stdout or "")

def gluster_create(name: str, replica: int, transport: str, bricks):
    host = pick_local_brick_host()
    brick_specs = [f"{host}:{str(p)}" for p in bricks]
    if not host_seems_local(host):
        log(f"Warnung: BRICK_HOST '{host}' scheint weiterhin nicht lokal zu sein (unerwartet).")
    log(f"Brick host for volume '{name}': {host}")
    log("Bricks:", ", ".join(brick_specs))
    brick_args = " ".join(shlex.quote(b) for b in brick_specs)
    cmd = f"gluster volume create {shlex.quote(name)} replica {int(replica)} transport {transport} {brick_args} force"
    run(cmd)

def gluster_start(name: str):
    run(f"gluster volume start {shlex.quote(name)}", check=False)

def gluster_set_option(name: str, key: str, val: str):
    run(f"gluster volume set {shlex.quote(name)} {shlex.quote(key)} {shlex.quote(val)}")

def gluster_reset_option(name: str, key: str):
    run(f"gluster volume reset {shlex.quote(name)} {shlex.quote(key)}")

def reconcile_from_yaml(name: str, vol: dict):
    if not volume_running(name): gluster_start(name)
    if "auth_allow" in vol:
        aa = vol["auth_allow"]
        if aa in ("", None): gluster_reset_option(name, "auth.allow")
        else: gluster_set_option(name, "auth.allow", str(aa))
    if "nfs_disable" in vol:
        val = "on" if bool(vol["nfs_disable"]) else "off"
        gluster_set_option(name, "nfs.disable", val)
    opts = vol.get("options") or {}
    if isinstance(opts, dict):
        for k, v in opts.items(): gluster_set_option(name, str(k), str(v))
    opts_reset = vol.get("options_reset")
    if isinstance(opts_reset, str): opts_reset = [x.strip() for x in opts_reset.split(",") if x.strip()]
    if isinstance(opts_reset, list):
        for k in opts_reset: gluster_reset_option(name, str(k))
    quota = vol.get("quota") or {}
    if quota.get("limit"):
        run(f"gluster volume quota {shlex.quote(name)} enable", check=False)
        run(f"gluster volume quota {shlex.quote(name)} limit-usage / {shlex.quote(str(quota['limit']))}", check=False)
        soft_raw = quota.get("soft_limit_pct")
        if soft_raw is not None:
            val = str(soft_raw).strip()
            if val.endswith('%'): val = val[:-1]
            try:
                pct = int(val)
            except ValueError:
                die(f"Ungültiger Wert für quota.soft_limit_pct: {soft_raw!r} (erwartet z.B. 80 oder '80%')")
            run(f"gluster volume quota {shlex.quote(name)} default-soft-limit {pct}", check=False)

def main():
    host = detect_brick_host()
    log(f"Detected brick host: {host}")
    path = find_yaml()
    if not path: log("Keine volumes.yml gefunden – nichts zu tun."); return
    vols = load_spec(path)
    for vol in vols:
        name = str(vol["name"])
        replica = int(vol.get("replica") or os.environ.get("REPLICA") or 1)
        transport = (vol.get("transport") or os.environ.get("TRANSPORT") or "tcp").lower()
        brick_roots = parse_bricks(replica)
        if len(brick_roots) < replica: die(f"BRICKS liefert {len(brick_roots)} Einträge, benötigt: replica={replica}")
        ensure_dirs(brick_roots)
        volume_bricks = [ (p / name).resolve() for p in brick_roots ]
        ensure_dirs(volume_bricks)
        # Preflight: ensure we can set trusted.* xattrs on the brick filesystem
        preflight_xattr(volume_bricks[0].parent)
        if not volume_exists(name): gluster_create(name, replica, transport, volume_bricks)
        reconcile_from_yaml(name, vol)
        # --- Zusammenfassung am Ende: Info/Status/Quota des/der Volumes ---
        try:
            for _vol in vols:
                try:
                    volume_report(str(_vol.get("name")))
                except Exception as e:
                    log(f"Report-Fehler für Volume '{_vol.get('name', '?')}': {e}")
        except Exception as e:
            log(f"Report-Block übersprungen: {e}")

    log("Solo-Startup erfolgreich (idempotent).")

if __name__ == "__main__": main()
