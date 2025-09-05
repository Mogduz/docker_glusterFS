# Dockerfile — GlusterFS Server (Ubuntu 24.04) mit EINEM Persistenz-Mount (/gluster)
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    GLUSTER_ROOT="/gluster" \
    GLUSTER_CONFIG="/gluster/etc/cluster.yml" \
    GLUSTER_NODE="" \
    AUTO_PROBE_PEERS="true" \
    AUTO_CREATE_VOLUMES="false" \
    MANAGER_NODE="" \
    FAIL_ON_UNMOUNTED_BRICK="true" \
    BRICKS="" \
    ALLOW_SINGLE_BRICK="false"

# Server + YAML-Tools
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      glusterfs-server glusterfs-client acl attr procps yq jq iproute2 \
 && rm -rf /var/lib/apt/lists/*

# Defaults sichern & Symlinks auf /gluster setzen
# - Defaults landen unter /opt/glusterfs-defaults (für späteres Seeding)
# - /etc/glusterfs, /var/lib/glusterd, /var/log/glusterfs werden zu Symlinks
RUN mkdir -p /opt/glusterfs-defaults \
 && cp -a /etc/glusterfs/. /opt/glusterfs-defaults/ \
 && mkdir -p /gluster/etc /gluster/glusterd /gluster/logs /gluster/bricks \
 && rm -rf /etc/glusterfs /var/lib/glusterd /var/log/glusterfs \
 && ln -s /gluster/etc      /etc/glusterfs \
 && ln -s /gluster/glusterd /var/lib/glusterd \
 && ln -s /gluster/logs     /var/log/glusterfs

# Ports
EXPOSE 24007/tcp 24008/tcp 49152-49251/tcp

# Einziger Persistenz-Mount: /gluster
VOLUME ["/gluster"]

# Copy modular scripts
COPY ./src/scripts/ /opt/gluster-scripts/
RUN chmod +x /opt/gluster-scripts/entrypoint.sh \
    /opt/gluster-scripts/lib/*.sh

# Healthcheck: glusterd läuft?
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=5 \
  CMD pgrep -x glusterd >/dev/null || exit 1

# Entrypoint
CMD ["/opt/gluster-scripts/entrypoint.sh"]
