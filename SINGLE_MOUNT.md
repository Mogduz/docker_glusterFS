# Single central mount with runtime bootstrap

This repo includes `scripts/bootstrap.sh` that runs **before** the Python entrypoint:
- If `/mnt/data` is empty/missing, it creates the required tree and a minimal config (`role: server`).
- Symlinks `/etc/glusterfs`, `/etc/gluster-container`, `/var/lib/glusterd`, `/var/log/glusterfs`, `/bricks/brick1` to that tree.
- Optionally smoke-tests xattrs (non-fatal).
Compose mounts one folder: `./data:/mnt/data` and sets the entrypoint to `bootstrap.sh`.
