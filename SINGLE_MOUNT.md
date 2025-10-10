
# Single-mount autobootstrap

Mount a single host folder to `/mnt/data`. On startup the container:
- Creates a minimal tree if `/mnt/data` is empty (etc/glusterfs, etc/gluster-container, var/lib/glusterd, log/glusterfs, bricks/brick1/gv0)
- Writes a default `etc/gluster-container/config.yaml` (`role: server`) if missing
- Symlinks system paths to that tree (idempotent)
- Optionally smoke-tests xattrs on the brick

Compose:
  volumes:
    - ./data:/mnt/data:rw

Env:
  MOUNT_ROOT=/mnt/data  # to change the root path inside the container
