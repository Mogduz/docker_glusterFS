# -----------------------------------------------------------------------------
# GlusterFS Hybrid Image (Ubuntu 24.04)
# This Dockerfile builds a single image that can act as:
#   - a Gluster **server** (runs glusterd, expects host network and brick bind-mounts),
#   - a **server+bootstrap** node (idempotently probes peers and creates the volume),
#   - a **client** (performs FUSE mounts inside the container and shares them to the host),
#   - or a **noop** container for debugging.
#
# Design notes:
# - All Gluster state is persisted on the *host* via bind-mounts. Rebuild/redeploy
#   containers without losing data.
# - Server containers should use `network_mode: host` for proper port handling.
# - Health checks are included via scripts/healthcheck.sh.
# -----------------------------------------------------------------------------
# glusterfs-hybrid: Ubuntu 24.04 based GlusterFS server/client hybrid
# Roles: server | server+bootstrap | client | noop
ARG BASE_IMAGE=ubuntu:24.04
FROM ${BASE_IMAGE}
ENV DEBIAN_FRONTEND=noninteractive TZ=Europe/Berlin
RUN apt-get update && apt-get install -y --no-install-recommends \
      glusterfs-server glusterfs-client xfsprogs attr python3 python3-yaml tini ca-certificates \
    && rm -rf /var/lib/apt/lists/*
# Persisted state (bind from host)
ENV PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ENV GLUSTERD_BIN="/usr/sbin/glusterd"
VOLUME ["/etc/glusterfs", "/var/lib/glusterd", "/var/log/glusterfs", "/bricks"]
# Informational expose; use host network mode for servers
EXPOSE 24007 24008
COPY entrypoint.py /usr/local/bin/entrypoint.py
COPY scripts/healthcheck.sh /usr/local/bin/healthcheck.sh
RUN chmod +x /usr/local/bin/entrypoint.py /usr/local/bin/healthcheck.sh\
 && echo "BUILD SANITY: verify glusterd is daemon (not client)"\
 && set -eux; : build_sanity ; \
 real="$(readlink -f $(command -v glusterd))"; \
 dpkg -S "$real" | grep -q "glusterfs-server" || { echo "FATAL: $(command -v glusterd) not owned by glusterfs-server"; dpkg -S "$real" || true; exit 19; }; \
 test -s /usr/share/man/man8/glusterd.8.gz || { echo "FATAL: glusterd manpage missing -> incomplete server install"; exit 19; }; \
 command -v glusterd; (glusterd --version || true)
ENTRYPOINT ["/usr/bin/tini","--","/usr/local/bin/entrypoint.py"]
# Default config path; can be overridden by CMD/args or ENV CONFIG_PATH
CMD ["/etc/gluster-container/config.yaml"]
HEALTHCHECK --interval=30s --timeout=10s --retries=3 CMD /usr/local/bin/healthcheck.sh || exit 1
