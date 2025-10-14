# GlusterFS Solo (2 Bricks) — Fixed

This bundle fixes the `starting` hang by:
- Running `glusterd` **in the foreground** (`-N`), no systemd needed.
- Using **host networking** so all Gluster ports are reachable.
- Adding **privileged + /dev/fuse + SYS_ADMIN** only if you decide to do FUSE mounts inside the container (not required just to run `glusterd`).
- A **healthcheck** that only pings the daemon; no mounts needed.
- Optional auto-create of a *replica-2* volume (`gv0`) on two local bricks in the same node (**uses `force`**).

## Quick start

```bash
# from this folder
docker compose build
docker compose up -d
# check:
docker ps
docker logs -f gluster-solo
gluster --mode=script volume info gv0
```

Mount from a client node (Linux):
```bash
sudo apt-get install glusterfs-client   # or your distro equivalent
sudo mkdir -p /mnt/gluster
sudo mount -t glusterfs gluster-solo:/gv0 /mnt/gluster
```

## Notes

- If you don't plan to issue *mounts* from inside the container, `/dev/fuse` and `SYS_ADMIN` are not strictly required, but they do no harm here.
- `docker-compose.yml` intentionally **omits** the obsolete top-level `version` key (Compose v2 ignores it).
- Ports used by Gluster: `24007`, `24008`, and **one port per brick starting at 49152** (hence host networking to avoid mapping the range).
