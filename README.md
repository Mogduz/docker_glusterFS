# GlusterFS Server in Docker (Ubuntu 24.04)

A production‑ready Docker image for running a **GlusterFS server** on **Ubuntu 24.04 (Noble)** — designed for **host bind mounts**, **declarative YAML configuration**, and **safe-by-default** bootstrapping.

This repository contains:
- A minimal **Dockerfile** that installs `glusterfs-server` and tooling (`yq`, `jq`).
- A **chatty entrypoint** that validates mounts, reads a **YAML cluster configuration**, optionally **probes peers**, and **creates/starts volumes** idempotently.
- A **single persistent root mount** (`/gluster`) for **state**, **config**, and **logs** via symlinks, and **dedicated bind mounts per brick** for data.
- Examples for `docker run` and **docker‑compose**.

> ⚠️ This image intentionally **does not use systemd**. The management daemon is launched with `glusterd -N` in the foreground and supervised by the container runtime.

---

## TL;DR

```bash
# Host: create persistence + brick folders
sudo mkdir -p /srv/gluster/{etc,glusterd,logs}
sudo mkdir -p /data/gluster/{vol1_brick,vol2_brick}

# Write a simple cluster.yml
cat >/srv/gluster/etc/cluster.yml <<'YAML'
manager_node: gluster1
peers: [gluster1]
local_bricks:
  - /gluster/bricks/vol1/brick
  - /gluster/bricks/vol2/brick
volumes:
  - name: gv0
    type: distribute
    bricks:
      - gluster1:/gluster/bricks/vol1/brick
      - gluster1:/gluster/bricks/vol2/brick
    options: { nfs.disable: "on" }
YAML

# Run the container (single persistence mount + per‑brick mounts)
docker run -d --name gluster1 --hostname gluster1 \
  --ulimit nofile=65536:65536 \
  -p 24007:24007 -p 24008:24008 -p 49152-49251:49152-49251 \
  -v /srv/gluster:/gluster \
  -v /data/gluster/vol1_brick:/gluster/bricks/vol1/brick \
  -v /data/gluster/vol2_brick:/gluster/bricks/vol2/brick \
  -e AUTO_CREATE_VOLUMES=true \
  drezael/glusterfs:0.1
```

---

## Why this image?

- **Host‑first storage**: Bricks live on host **ext4** (or your FS of choice) and are mounted **one by one** into the container — no hidden data in container layers.
- **Single persistence mount**: `/gluster` holds **state**, **config**, and **logs** — simple backups and clean portability.
- **Declarative setup**: A small **YAML file** defines peers, local bricks, and volumes. The entrypoint applies it **idempotently**.
- **Safety guard**: Prevents accidental **single‑brick volumes** (SPoF). Can be overridden explicitly.
- **Verbose boot logs**: Clear step‑by‑step output to understand what happens at startup.

---

## Image contents

- `glusterfs-server`
- `yq`, `jq` for YAML/JSON parsing in the entrypoint
- `acl`, `attr`, `procps` (for ACL/xattrs and health checks)
- **No systemd**; runs `glusterd` in the foreground

---

## Design & Layout

- **Single persistence root**: You bind‑mount **one** host directory to `/gluster`.
  - `/var/lib/glusterd` → symlink to `/gluster/glusterd`
  - `/etc/glusterfs`   → symlink to `/gluster/etc`
  - `/var/log/glusterfs` → symlink to `/gluster/logs`
- **Bricks**: Bind‑mount each brick explicitly, e.g. `/data/gluster/vol1_brick:/gluster/bricks/vol1/brick`.
- **Ports**: `24007/tcp` (mgmt), `24008/tcp`, and `49152–49251/tcp` (brick port range).

---

## Configuration file (`cluster.yml`)

A declarative YAML that can live at `/gluster/etc/cluster.yml` (default) and is read by the entrypoint.

### Example

```yaml
manager_node: gluster1            # Node that manages volume creation (avoids race conditions)

peers:                            # Optional list of peers; the entrypoint will 'peer probe' them
  - gluster1
  # - gluster2

local_bricks:                     # Brick paths on THIS node (checked & must be bind‑mounted)
  - /gluster/bricks/vol1/brick
  - /gluster/bricks/vol2/brick

volumes:
  - name: gv0
    type: distribute              # distribute | replicate | disperse
    transport: tcp
    bricks:
      - gluster1:/gluster/bricks/vol1/brick
      - gluster1:/gluster/bricks/vol2/brick
    options:
      nfs.disable: "on"
      performance.client-io-threads: "on"
```

### Replicated volume across two nodes (example)

```yaml
manager_node: gluster1
peers: [gluster1, gluster2]

local_bricks:
  - /gluster/bricks/vol1/brick     # on each node: a different underlying host path

volumes:
  - name: gv_repl2
    type: replicate
    replica: 2
    transport: tcp
    bricks:
      - gluster1:/gluster/bricks/vol1/brick
      - gluster2:/gluster/bricks/vol1/brick
    options:
      cluster.quorum-type: "auto"
      nfs.disable: "on"
```

> For **disperse** volumes define `disperse_count` and `redundancy` and provide exactly `disperse_count` bricks.

---

## Environment variables

| Variable | Default | Description |
|---------|---------|-------------|
| `GLUSTER_ROOT` | `/gluster` | Single persistence mount containing `etc`, `glusterd`, and `logs`. |
| `GLUSTER_CONFIG` | `/gluster/etc/cluster.yml` | Path to YAML config. |
| `GLUSTER_NODE` | *(hostname -s)* | Friendly node name override. |
| `AUTO_PROBE_PEERS` | `true` | Probe peers listed in `peers:` on startup. |
| `AUTO_CREATE_VOLUMES` | `false` | Create/set/start volumes from YAML (idempotent). |
| `MANAGER_NODE` | *(unset)* | Only this node performs volume management. Fallback: `manager_node` in YAML. |
| `FAIL_ON_UNMOUNTED_BRICK` | `true` | Fail fast if a brick path is not a bind‑mount. |
| `BRICKS` | *(unset)* | Optional comma‑separated additional local brick paths. |
| `ALLOW_SINGLE_BRICK` | `false` | Safety guard: if a volume has exactly **1 brick**, fail unless set to `true`. |

---

## Usage

### Docker Compose

`docker-compose.yml`:

```yaml
version: "3.9"
services:
  gluster1:
    image: drezael/glusterfs:0.1
    container_name: gluster1
    hostname: gluster1
    restart: unless-stopped
    ulimits: { nofile: 65536 }
    ports:
      - "24007:24007"
      - "24008:24008"
      - "49152-49251:49152-49251"
    environment:
      AUTO_PROBE_PEERS: "true"
      AUTO_CREATE_VOLUMES: "true"
      MANAGER_NODE: "gluster1"
      FAIL_ON_UNMOUNTED_BRICK: "true"
      ALLOW_SINGLE_BRICK: "false"
    volumes:
      - /srv/gluster:/gluster
      - /data/gluster/vol1_brick:/gluster/bricks/vol1/brick
      - /data/gluster/vol2_brick:/gluster/bricks/vol2/brick
```

Bring it up:

```bash
docker compose up -d
docker logs -f gluster1
```

### Plain `docker run`

See the TL;DR at the top.

---

## Multi‑node quick start (replica 2)

1. Prepare both hosts with brick folders and `/srv/gluster`.
2. Use identical `cluster.yml` on both; set correct `hostname` and `MANAGER_NODE` (e.g. `gluster1`).
3. Start both containers (expose ports or use `--network host` in a trusted network).
4. On first run the manager node will probe the other, create the volume, set options, and start it.

> After adding bricks, remember to run `gluster volume rebalance <VOL> start` for distribute layouts.

---

## Healthcheck & Logging

- **Healthcheck**: checks that `glusterd` is running (`pgrep -x glusterd`).  
- **Logs**: written under `/gluster/logs`. You can `docker logs` for the entrypoint chatter and tail the Gluster logs on the host.

---

## Troubleshooting

- **`ERROR: Persistenz-Mount /gluster not detected`**  
  Ensure `-v /srv/gluster:/gluster` is present.

- **`ERROR: Brick not mounted`**  
  Bind‑mount each brick (e.g. `-v /data/vol1:/gluster/bricks/vol1/brick`). Set `FAIL_ON_UNMOUNTED_BRICK=false` only for tests.

- **Single brick volume error**  
  Either set `ALLOW_SINGLE_BRICK=true` (test only) or add more bricks / change to `replicate` with `replica: N`.

- **Peer probe keeps retrying**  
  Check connectivity and hostnames/DNS. Ensure ports are reachable; consider `--network host`.

- **Volume create fails for replicate/disperse**  
  Verify brick count matches `replica` or `disperse_count`. The entrypoint prints an explicit reason and exits.

---

## Building the image

```bash
# Build & push with buildx
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --output type=registry \
  -t drezael/glusterfs:0.1 \
  .
```

For local single‑arch testing:

```bash
docker build -t drezael/glusterfs:dev .
```

---

## Security notes

- Run on trusted hosts/networks. Exposed ports should be firewalled properly.
- Data durability depends on the host filesystem (e.g., ext4 with ACL/xattrs enabled).
- Consider `replicate` or `disperse` topologies for redundancy; `distribute` alone offers no data protection.

---

## License

This repository is intended to be licensed under your chosen open‑source license (e.g., Apache‑2.0/MIT).  
Add a `LICENSE` file at the repository root and adjust this section accordingly.

---

## Acknowledgements

- GlusterFS project and documentation
- Community examples and best practices around containerized Gluster nodes

---

## Network isolation: bind to a specific internal IP (no new networks)

If your host already has two network interfaces (e.g., one public and one **internal**) and you want the container to listen **only** on the internal address (e.g., `10.0.1.2`), you don't need any special Docker networks and you **do not** need to change the Dockerfile. Simply bind the published ports to the internal host IP.

### docker-compose
```yaml
version: "3.9"
services:
  gluster1:
    image: drezael/glusterfs:0.1
    container_name: gluster1
    hostname: gluster1
    restart: unless-stopped
    ulimits: { nofile: 65536 }
    ports:
      - "10.0.1.2:24007:24007"                 # glusterd (mgmt)
      - "10.0.1.2:24008:24008"
      - "10.0.1.2:49152-49251:49152-49251"     # brick port range
    volumes:
      - /srv/gluster:/gluster
      - /data/gluster/vol1:/gluster/bricks/vol1/brick
      # - /data/gluster/vol2:/gluster/bricks/vol2/brick
    environment:
      AUTO_PROBE_PEERS: "true"
      AUTO_CREATE_VOLUMES: "true"
      MANAGER_NODE: "gluster1"
```

### docker run
```bash
docker run -d --name gluster1 --hostname gluster1 \
  --ulimit nofile=65536:65536 \
  -p 10.0.1.2:24007:24007 \
  -p 10.0.1.2:24008:24008 \
  -p 10.0.1.2:49152-49251:49152-49251 \
  -v /srv/gluster:/gluster \
  -v /data/gluster/vol1:/gluster/bricks/vol1/brick \
  -e AUTO_PROBE_PEERS=true \
  -e AUTO_CREATE_VOLUMES=true \
  -e MANAGER_NODE=gluster1 \
  drezael/glusterfs:0.1
```

**Notes**
- Only the internal address `10.0.1.2` will accept connections; nothing is bound on the public interface.
- In your `cluster.yml`, use the internal IPs/hostnames for peers.
- Outbound traffic still follows the host’s routing; if you want to block Internet egress, do that in the host firewall.
- Verify binding on the host:
  ```bash
  ss -ltnp | grep -E '24007|24008|4915[2-9][0-9]|492[0-4][0-9]|4925[0-1]'
  # Output should show 10.0.1.2:PORT, not 0.0.0.0:PORT
  ```
