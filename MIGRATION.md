
# Notes on Ubuntu 24.04 (Noble) vs. 22.04 (Jammy)

Some minimal images of Ubuntu 24.04 have been observed to ship a `glusterd` binary that prints *client* help
(`--volfile` / `MOUNT-POINT`) instead of the expected daemon options. When this happens, the management daemon will not start.

This repo now:

- **Preflights** the `glusterd` binary and clearly aborts if a *client* binary is detected (exit code 27).
- Lets you **override** the binary via `GLUSTERD_BIN` (env var).
- Lets you **pin the base** via `UBUNTU_TAG` build-arg in the Dockerfile (default `24.04`).

## If you hit the client-binary bug

1. Try pinning the base to 22.04 (Jammy), where server packaging is known-good:

```yaml
# compose.server.yml
services:
  glusterd:
    build:
      context: .
      args:
        UBUNTU_TAG: "22.04"
    image: ghcr.io/yourorg/glusterfs-hybrid:ubuntu22
```

2. Or, point `GLUSTERD_BIN` to the correct daemon path if available in your image, e.g.:

```yaml
environment:
  - GLUSTERD_BIN=/usr/sbin/glusterd
```

If preflight still aborts with code 27, the *server* bits likely aren't present. Install `glusterfs-server`.
