
# Base OS pinning: Ubuntu 22.04 (Jammy)

Due to `glusterd` in some Ubuntu 24.04 images resolving to a *client*-style binary, this repo pins
the base to **Ubuntu 22.04 (Jammy)** where `glusterfs-server` reliably provides the management daemon.

- Dockerfile: `FROM ubuntu:22.04`
- compose.server.yml: image tag renamed to `...:ubuntu22`

If you later want to try Noble (24.04), revert both, rebuild with `--no-cache`, and ensure
the preflight doesn't detect client-style help (`MOUNT-POINT`/`--volfile`).