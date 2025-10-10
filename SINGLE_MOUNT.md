# Single-mount autobootstrap (/mnt/data)

On container start:
- If `/mnt/data` is missing **or empty**, the container creates:
  - `etc/glusterfs`, `etc/gluster-container`, `var/lib/glusterd`, `log/glusterfs`, `bricks/brick1/gv0`
  - `etc/gluster-container/config.yaml` with `role: server` (if missing)
- It symlinks system paths to the tree under `/mnt/data` (idempotent).
- If everything exists, bootstrap is skipped.

Compose:
  volumes:
    - ./data:/mnt/data:rw

You can override the target via `MOUNT_ROOT` env (default `/mnt/data`).
