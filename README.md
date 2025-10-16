# Gluster Solo (2 Bricks)

This stack runs a single Gluster server with two bricks. It is designed so a client
on another host in your private network (e.g. `10.1.0.0/16`) can mount the volume.

## Why mounts failed before

Gluster bricks listen on **ephemeral data ports** in the high range. Your compose
previously published only `49152–49251`, but bricks were binding to ports like
`50948` and `57098`, which were **not** published. The client could reach
management `24007` but failed to reach brick ports → `All subvolumes are down`.

## Fix

We now publish `49152–60999` to match `MAX_PORT=60999` and cap Gluster to that same
upper bound. Adjust your firewall accordingly.

## Quick start

1. Copy `.env.example` to `.env` and review values (especially `HOST_BRICK1/2` paths,
   `PRIVATE_IP`, and `AUTH_ALLOW`).
2. Create the brick paths on the Docker host if they do not exist.
3. `docker compose up -d`
4. On the client host: `mount -t glusterfs gluster-solo:/gv0 /mnt/gluster`

## Notes

- Avoid assigning your Docker bridge network to `10.1.0.0/16` to prevent routing clashes.
- If you prefer, switch the service to `network_mode: host` and remove the `ports:` block
  entirely; then open ports in your host firewall instead.

## Variant B — Bind to private IP (no host network)

This variant publishes Gluster management and data ports **only** on the host's private IP from `.env` (`PRIVATE_IP`).
The Internet-facing interface is not bound; `docker ps` will show exact mappings on the private IP.

**Requirements**
- `.env`: `PRIVATE_IP` set (e.g., `10.0.1.2`).
- `DATA_PORT_START=49152`, `DATA_PORT_END=60999`, `MAX_PORT=60999` kept consistent.
- Host brick paths exist and are mapped.

**Start**
```bash
docker compose -f compose.bound-to-private.yml up -d --build
```

**Verification**
```bash
docker ps | grep gluster-solo
gluster volume status
```

**Client mount**
```bash
mount -t glusterfs ${PRIVATE_IP}:/gv0 /mnt/gluster
```

### Auto-override (recommended)

If you want these bindings to apply to **any** existing compose file (even those with `network_mode: host`),
use the provided `docker-compose.override.yml` (already included). Compose will merge it automatically:

```bash
docker compose up -d --build
```

The override disables `network_mode: host`, creates a bridge network, and publishes all required ports **on `${PRIVATE_IP}` only**.
