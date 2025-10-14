# GlusterFS in Docker — ENV‑driven, single‑image setup

This repository provides a **single GlusterFS server image** that can run a local, lab, or single‑host multi‑brick setup. 
The stack is **ENV‑driven**: all configuration lives in `.env`. Brick bind mounts are generated from `HOST_HOST_BRICK* (autodiscovered inside the container)` via a small helper script.

**No Makefile.** You operate the stack directly with Docker Compose.

---
## What’s included
- **`Dockerfile`** — Debian slim + `glusterfs-server`/`glusterfs-client` + `tini`.      Entrypoint is `entrypoint.sh` inside the container.
- **`docker-compose.yml`** — Base compose that:
  - loads variables from **`.env` only** (see `env_file` section),
  - persists Gluster state at `/var/lib/glusterd` via the named volume **`glusterd`**,
  - leaves brick bind mounts to the generated override.
- **`scripts/gen-compose-override.py`** — Reads `HOST_HOST_BRICK* (autodiscovered inside the container)` from `.env`, generates **`—`** with bind mounts, and writes **`HOST_BRICK* (autodiscovered inside the container)`** back into `.env` (container targets `/bricks/brick1..N`).
- **`entrypoint.sh`** — Starts `glusterd`, waits for readiness, prepares bricks from `HOST_BRICK* (autodiscovered inside the container)`, optionally creates the volume idempotently and applies volume options.

---
## Prerequisites
- Linux host with Docker Engine and Docker Compose plugin.
- Filesystem supporting **extended attributes (xattrs)** for brick paths (e.g., ext4 or xfs).
- Consider enabling AppArmor/SELinux allowances when bind mounting host paths (see Troubleshooting).

---
## Quickstart (ENV‑only, no Makefile)
1) Create your `.env` from the template and set host brick paths:
   ```bash
   cp .env.example .env
   # Edit and set comma‑separated host paths (absolute paths recommended)
   # Example:
   # HOST_HOST_BRICK* (autodiscovered inside the container)=/mnt/disk1/gluster/brick1,/mnt/disk2/gluster/brick2
   ```
2) Generate the brick override and let it populate `HOST_BRICK* (autodiscovered inside the container)`:
   ```bash
      # Creates —
   # Writes HOST_BRICK* (autodiscovered inside the container)=/bricks/brick1,/bricks/brick2 into .env
   ```
3) Bring the stack up:
   ```bash
   docker compose up -d
   ```
4) Verify:
   ```bash
   docker compose ps
   docker exec -it gluster-solo gluster volume info
   ```

---
## Configuration

**Main ENV file:** `.env` (copied from `.env.example`). The compose file references variables via `$Ellipsis`. Key variables detected in this repo include:

- **Compose / runtime**
  - `CONTAINER_NAME, DATA_PORT_END, DATA_PORT_START, HC_INTERVAL, HC_RETRIES, HC_TIMEOUT, HOSTNAME_GLUSTER, MGMT_PORT1, MGMT_PORT2
- **Entrypoint / Gluster behavior (excerpt)**
  - `ADDRESS_FAMILY, ALLOW_EMPTY_STATE, ALLOW_FORCE_CREATE, AUTH_ALLOW, BRICK_PATH, HOST_BRICK* (autodiscovered inside the container), CREATE_VOLUME, HOSTNAME, LOG_LEVEL, MAX_PORT, MODE, NFS_DISABLE, PEERS, REPLICA, REQUIRE_ALL_PEERS, TRANSPORT, TZ, UMASK, VOLNAME, VOL_OPTS, VTYPE, bp, force, host
- **Generator**
  - `HOST_HOST_BRICK* (autodiscovered inside the container)` (comma‑separated host directories for bricks) → required
  - `HOST_BRICK* (autodiscovered inside the container)` (container targets) → **auto‑written** by the generator

> Tip: `HOST_HOST_BRICK* (autodiscovered inside the container)` determines how many bricks you run. The generator maps them to `/bricks/brick1..N` automatically and writes that list into `HOST_BRICK* (autodiscovered inside the container)` for the entrypoint.

**Ports**
- Management: `${MGMT_PORT1}` (default 24007), `${MGMT_PORT2}` (24008)
- Data range: `${DATA_PORT_START}`‑`${DATA_PORT_END}` (default 49152‑49251)

**Volume creation**
- The entrypoint can create a volume idempotently based on the supplied variables (e.g., `VOLNAME`, `VTYPE`, `REPLICA`, `CREATE_VOLUME`, `ALLOW_FORCE_CREATE`).      If a volume already exists, it will be started and configured.

**Access control**
- `AUTH_ALLOW` is applied to the Gluster volume (comma‑separated CIDRs or hosts).      Keep Docker‑exposed ports restricted at the host firewall level as well.

---
## Generated override

The override is intentionally small and only contains **bind mounts** like:
```yaml
services:
  gluster-solo:
    volumes:
      - type: bind
        source: /mnt/disk1/gluster/brick1
        target: /bricks/brick1
        bind:
          create_host_path: true
      - type: bind
        source: /mnt/disk2/gluster/brick2
        target: /bricks/brick2
        bind:
          create_host_path: true
```
The container then receives `HOST_BRICK* (autodiscovered inside the container)=/bricks/brick1,/bricks/brick2` in `.env` (written by the generator).

---
## Security & performance notes
- **auth.allow**: always restrict to client networks (`AUTH_ALLOW`).      Combine with host firewall rules restricting Gluster ports to trusted ranges.
- **File descriptors**: consider increasing `nofile` ulimit if you expect many connections.
- **SELinux**: when bind mounting on SELinux systems, use `:z` or `:Z` or set appropriate labels.
- **AppArmor**: the compose config uses `apparmor:unconfined` to avoid xattr issues in some setups.
- **Docker Desktop**: running Gluster inside Docker Desktop (macOS/Windows) is not supported — xattrs and FUSE semantics are unreliable there.

---
## Troubleshooting
- **“Operation not permitted” / xattrs** — verify your host filesystem supports xattrs and that security policies allow them. The container adds `SYS_ADMIN` and relaxes AppArmor to help.
- **Ports not reachable** — confirm that `${MGMT_PORT1}`, `${MGMT_PORT2}`, and the data range are exposed and permitted by your firewall.
- **Volume not created** — ensure `CREATE_VOLUME=1`, `ALLOW_FORCE_CREATE=1` (for replica‑2 prompts), and that `HOST_BRICK* (autodiscovered inside the container)` lists all container brick targets.
- **Peer clustering** — this setup targets single‑host/multi‑brick labs. If you need multi‑host clusters, add peer probing and a leader node orchestration step (not covered here).

---
## Housekeeping
- The repository keeps only the **base compose** and the **state named volume**. Brick directories are **not** committed.
- Generated files:
  - `—` (bind mounts) — ignored by Git
  - `.env` (your live configuration) — never commit secrets

---
## License
See the repository’s license file if present.


---
## Brick mapping (env‑only, no override)
This stack uses two standard bricks bound from host paths via the local volume driver.
Configure them in `.env`:
```env
HOST_BRICK1=/mnt/brick1
HOST_BRICK2=/mnt/brick2
```
The service mounts them as `/bricks/brick1` and `/bricks/brick2`. If you change `REPLICA`, ensure the brick count matches.
