# GlusterFS Server – minimal, server-only
FROM debian:12-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      glusterfs-server glusterfs-client fuse3 tini ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# Documented ports (publish via compose/run)
EXPOSE 24007 24008 49152-60999
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Run glusterd in foreground (-N) under tini for proper signal handling
ENTRYPOINT ["/usr/bin/tini","--","/usr/local/bin/entrypoint.sh"]