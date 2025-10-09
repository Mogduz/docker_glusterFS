# glusterfs-hybrid (Ubuntu 24.04)

A **hybrid** GlusterFS container image for Ubuntu 24.04 that can be configured to run as a
- **Server** (`role: server`),
- **Server with bootstrap** (`role: server+bootstrap`),
- **Client** (`role: client`), or
- **noop** (do nothing; for debugging)

**Key feature:** In **client mode** the container mounts the Gluster volume inside the container and, thanks to **bind-mount with `propagation: rshared`**, that mount is *mirrored on the host* at the same path for as long as the container runs. When the container stops cleanly, the volume is unmounted and the host path becomes “empty” again.

> Tested on: Ubuntu 24.04 LTS, Docker Engine 24+, Compose v2.

---

## Table of contents
- [Architecture](#architecture)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Configuration](#configuration)
  - [Server](#server)
  - [Server + bootstrap](#server--bootstrap)
  - [Client](#client)
- [Healthcheck & logs](#healthcheck--logs)
- [Security & permissions](#security--permissions)
- [Troubleshooting](#troubleshooting)
- [Production checklist](#production-checklist)
- [License](#license)

---

## Architecture

- **State on the host**: `/etc/glusterfs`, `/var/lib/glusterd`, `/var/log/glusterfs`, and brick paths (e.g. `/data/brick1/brick`).
- **Server containers** run `glusterd` in the foreground (`-N`) and use the **host network**.
- The **client container** ships with FUSE, mounts a volume inside the container and exposes it to the host via a bind-mount with `propagation: rshared`.
- **No single “master”** in Gluster. The `server+bootstrap` role performs one-off cluster setup (peers & volume); afterwards all nodes are **equal**.

**Ports** (open in your firewall if applicable):  
- Management: **TCP 24007/24008**  
- One port **per brick starting at 49152** (typical range 49152–49251)

---

## Requirements

- Ubuntu 24.04 LTS hosts with Docker Engine ≥ 24 and `docker compose` (v2).
- For **server containers**: `network_mode: host`, brick directories bind-mounted from the host.
- For **client containers**: `/dev/fuse`, `CAP_SYS_ADMIN`, `security_opt: apparmor:unconfined`, and a bind-mount of the target path with **`propagation: rshared`**.

> **Preparation note:** On typical Ubuntu 24.04 setups you may need to ensure mount-propagation is enabled so the container mount becomes visible on the host; see [Troubleshooting](#troubleshooting).

---

## Quick start

Use the sample compose files and configs in `examples/`.

**Client**
1. Create `/mnt/glusterFS` on the host.  
2. Start the client container using `compose.client.yml` and `examples/config.client.yaml`.  
3. Result: Inside the container, `gfs1:/gv0` is mounted at `/mnt/glusterFS`, and thanks to `rshared` the mount appears **on the host at the same path**.  
4. `docker stop gluster-client` → clean **unmount** → the host path is “empty” again.

**Server**
- Bring up a server on each Gluster node host using `compose.server.yml` and `examples/config.server.yaml`.  
- For an initial cluster bring-up, start one node with `role: server+bootstrap` and `examples/config.server-bootstrap.yaml` to probe peers and create the volume idempotently.

---

## Configuration

### Server
`examples/config.server.yaml`
```yaml
role: "server"
node:
  hostname: "gfs1"
bricks:
  - path: "/bricks/brick1/brick"   # bind host /data/brick1 -> /bricks/brick1
```

### Server + bootstrap
`examples/config.server-bootstrap.yaml`
```yaml
role: "server+bootstrap"
cluster:
  peers: ["gfs2","gfs3"]
volume:
  name: "gv0"
  type: "replica"         # replica | distribute | disperse
  replica: 3              # for arbiter: replica: 3, arbiter: 1
  arbiter: 0              # set to 1 to use replica 3 arbiter 1
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

---

## Healthcheck & logs

- The image contains a simple healthcheck script (`scripts/healthcheck.sh`) that:
  - On **client** checks that the configured mount target is a mountpoint.
  - On **server** checks that `glusterd` is running and the CLI responds.
- Logs are written to `/var/log/glusterfs` (persisted via bind-mount on the host) and to the container stdout/stderr.

---

## Security & permissions

- The client container needs `/dev/fuse`, `CAP_SYS_ADMIN`, and `apparmor:unconfined` to perform FUSE mounts.
- Brick directories should be owned by the appropriate Gluster user/group and have the correct SELinux/AppArmor context where applicable.
- Prefer dedicated filesystems (XFS/ext4) for bricks, with the brick root as a subdirectory `brick/`.

---

## Troubleshooting

- **Mount not visible on host**: Ensure your bind-mount for the target path uses `propagation: rshared` and that the host mount namespace supports shared propagation.
- **Peer/volume commands fail**: Verify firewall rules (24007/24008 and brick ports ≥ 49152) and that hostnames resolve between nodes.
- **Clean shutdown**: Stopping the client container should unmount the target path automatically; if not, check for busy files and unmount manually.

---

## Production checklist

- **Ports**: Open 24007/24008; brick ports starting at 49152 (e.g. range 49152–49251).  
- **Time sync**: chrony/ntp on all hosts.  
- **Brick layout**: Dedicated filesystems (XFS/ext4), brick root as subfolder `brick/`.  
- **Heals**: Regularly check/monitor `gluster volume heal <vol> info`.  
- **Backups**: Snapshot/backup at the brick level or via client mounts.  
- **Monitoring**: Logs, `gluster` CLI metrics; optionally a Prometheus exporter (external).  
- **Updates**: Build a new image and restart containers (state lives on the host).

---

## License

See the `LICENSE` file for the current licensing terms.
