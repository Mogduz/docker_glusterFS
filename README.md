# glusterfs-hybrid (Ubuntu 24.04)
Ein **hybrides** GlusterFS-Container-Image für Ubuntu 24.04, das per Konfiguration als
- **Server** (`role: server`),
- **Server mit Bootstrap** (`role: server+bootstrap`),
- **Client** (`role: client`) oder
- **noop** (nichts tun, nur für Debug)
läuft.

**Wichtiges Feature:** Im **Client-Mode** mountet der Container ein GlusterFS-Volume **in den Containerpfad** (z. B. `/mnt/glusterFS`). Dank **Mount-Propagation `rshared`** taucht derselbe Mount **automatisch auf dem Host** unter **dem gleichen Pfad** auf – **nur solange der Client läuft**. Stoppt der Container sauber, wird ausgehängt und der Host-Pfad ist wieder „leer“.

> Tested on: Ubuntu 24.04 LTS, Docker Engine 24+, Compose v2.

---

## Inhaltsverzeichnis
- [Architektur](#architektur)
- [Voraussetzungen](#voraussetzungen)
- [Schnellstart](#schnellstart)
  - [Image bauen](#image-bauen)
  - [Server auf drei Hosts](#server-auf-drei-hosts)
  - [Client-Mount (Mount nur solange der Client läuft)](#client-mount-mount-nur-solange-der-client-läuft)
- [Konfiguration](#konfiguration)
  - [Server](#server)
  - [Server + Bootstrap](#server--bootstrap)
  - [Client](#client)
- [Healthcheck & Logs](#healthcheck--logs)
- [Sicherheit & Rechte](#sicherheit--rechte)
- [Troubleshooting](#troubleshooting)
- [Production-Checkliste](#production-checkliste)
- [Lizenz](#lizenz)

---

## Architektur
- **State auf dem Host**: `/etc/glusterfs`, `/var/lib/glusterd`, `/var/log/glusterfs`, Brick-Pfade (z. B. `/data/brick1/brick`).
- **Server-Container** starten `glusterd` im Vordergrund (`-N`) und verwenden **Host-Netz**.
- **Client-Container** bringt FUSE mit, mountet ein Volume nach `/mnt/glusterFS` (oder ein anderes Ziel) und macht es via Bind-Mount mit `rshared` auf dem Host sichtbar.
- **Kein „Master“** in Gluster: `server+bootstrap` übernimmt einmalig die Initialisierung (Peers & Volume), danach sind alle Knoten **gleichberechtigt**.

**Ports** (wenn Firewall aktiv):  
- Management: **TCP 24007/24008**  
- Pro Brick **ein Port ab 49152** (typisch 49152–49251)

---

## Voraussetzungen
- Ubuntu 24.04 LTS Hosts mit Docker Engine ≥24 und `docker compose` (v2).
- Für **Server-Container**: `network_mode: host`, Brick-Verzeichnisse als Bind-Mounts.
- Für **Client-Container**: `/dev/fuse`, `CAP_SYS_ADMIN`, `security_opt: apparmor:unconfined` (je nach Profil), und ein Bind-Mount des Zielpfads mit **`propagation: rshared`**.

> **Hinweis zur „Vorbereitung“**: In typischen Ubuntu-24.04-Setups reicht das Compose mit `propagation: rshared`. Falls der Mount wider Erwarten **nicht** auf dem Host sichtbar wird, siehe [Troubleshooting](#troubleshooting).

---

## Schnellstart

### Image bauen
```bash
git clone <dieses-repo>
cd glusterfs-hybrid
docker build -t ghcr.io/yourorg/glusterfs-hybrid:ubuntu24 .
```

### Server auf drei Hosts
> Auf **jedem** Host denselben Dienst starten; nur Brick-Bind-Mounts anpassen.

1. Auf **gfs1** `compose.server.yml` verwenden und `examples/config.server-bootstrap.yaml` (angepasst) mounten:
   ```bash
   docker compose -f compose.server.yml up -d
   ```
   - `compose.server.yml` bindet `./examples/config.server.yaml` – tausche den Mount gegen `config.server-bootstrap.yaml` auf **gfs1** aus, wenn dieser Knoten bootstrappen soll.
2. Auf **gfs2/gfs3** `role: server` verwenden.

**Beispiel Brick-Layout:**  
Host `/data/brick1/brick` → Container `/bricks/brick1/brick` (Brick-Root immer als Unterordner `brick/`).

### Client-Mount (Mount **nur solange** der Client läuft)
1. `compose.client.yml` starten:
   ```bash
   docker compose -f compose.client.yml up -d
   ```
2. Ergebnis: Im Container wird `gfs1:/gv0` nach `/mnt/glusterFS` gemountet. **Durch `rshared`** erscheint der Mount **gleichzeitig auf dem Host** unter `/mnt/glusterFS`.  
3. `docker stop gluster-client` → sauberer **Unmount** → Host-Pfad ist wieder leer.

---

## Konfiguration

### Server
`examples/config.server.yaml`
```yaml
role: "server"
node:
  hostname: "gfs1"
bricks:
  - path: "/bricks/brick1/brick"
```

### Server + Bootstrap
`examples/config.server-bootstrap.yaml`
```yaml
role: "server+bootstrap"
cluster:
  peers: ["gfs2","gfs3"]
volume:
  name: "gv0"
  type: "replica"         # replica | distribute | disperse
  replica: 3
  arbiter: 0              # für Arbiter-Variante auf 1 setzen
  transport: "tcp"
  bricks:
    - "gfs1:/bricks/brick1/brick"
    - "gfs2:/bricks/brick1/brick"
    - "gfs3:/bricks/brick1/brick"
  options:
    performance.client-io-threads: "on"
    cluster.lookup-optimize: "on"
```

### Client
`examples/config.client.yaml`
```yaml
role: "client"
mounts:
  - remote: "gfs1:/gv0"
    target: "/mnt/glusterFS"
    opts: "backupvolfile-server=gfs2,_netdev,log-level=INFO"
```

**Override via ENV:**  
- `ROLE`, `CONFIG_PATH` (Pfad zur YAML) können als Umgebungsvariablen gesetzt werden.

---

## Healthcheck & Logs
- **Healthcheck** (im Image):  
  - **Client**: prüft `mountpoint` des ersten `target` (Standard: `/mnt/glusterFS`).  
  - **Server**: prüft `glusterd`-Prozess und `gluster`-CLI (`volume list` oder `peer status`).
- **Logs**:  
  - Server-Logs unter `/var/log/glusterfs` (persistiert durch Bind-Mount).  
  - Entrypoint schreibt Status ins Container-Stdout (sichtbar via `docker logs`).

---

## Sicherheit & Rechte
- **Server** benötigt **kein `--privileged`**, da kein systemd im Container läuft. Host-Netz ist notwendig (viele Ports, dynamische Brick-Ports).  
- **Client** benötigt `CAP_SYS_ADMIN` und `/dev/fuse` zum Mounten. `apparmor:unconfined` kann je nach Host-Profil nötig sein.  
- **Rootless Docker** ist für Client-FUSE-Mounts ungeeignet.

---

## Troubleshooting

### Mount taucht auf dem Host nicht auf
- In seltenen Setups ist die Mount-Propagation des Host-Pfads nicht `shared`. Prüfe per:
  ```bash
  findmnt -o TARGET,PROPAGATION /mnt/glusterFS
  ```
  Falls nicht `shared`:
  ```bash
  sudo mount --make-shared /mnt/glusterFS
  ```
  Dann Client-Container neu starten.

### Unmount schlägt fehl („Device busy“)
- Container erneut sauber stoppen/starten.
- Oder auf dem Host:
  ```bash
  sudo umount /mnt/glusterFS || sudo umount -l /mnt/glusterFS
  ```

### „Transport endpoint is not connected“
- Typisch nach Netzwerk-/Serverproblemen. Unmounten und neu mounten:
  ```bash
  sudo umount -l /mnt/glusterFS
  docker compose -f compose.client.yml up -d
  ```

### Rootless / Podman
- Nicht unterstützt für FUSE-Mounts im Container (fehlende Privilegien).

---

## Production-Checkliste
- **Ports**: 24007/24008 offen; Brick-Ports ab 49152 (Range z. B. 49152–49251).  
- **Zeit-Sync** (chrony/ntp) auf allen Hosts.  
- **Brick-Layout**: Dedizierte Filesysteme (XFS/ext4), Brick-Root als Unterordner `brick/`.  
- **Heals**: `gluster volume heal <vol> info` regelmäßig prüfen/monitoren.  
- **Backups**: Snapshot/Backup auf Brick-Ebene oder via Client-Mount.  
- **Monitoring**: Logs, `gluster`-CLI-Metriken; optional Prometheus-Exporter (extern).  
- **Updates**: Neues Image bauen, Container neu starten (State bleibt auf dem Host).

---

## Lizenz
MIT – siehe `LICENSE`.
