ARG BASE_IMAGE=debian:12-slim
FROM ${BASE_IMAGE}

# gluster + useful tools
ARG DEBIAN_FRONTEND=noninteractive
ENV DEBIAN_FRONTEND=${DEBIAN_FRONTEND}
ARG GLUSTER_PACKAGES="bash tini glusterfs-server glusterfs-client procps dnsutils iproute2 util-linux"
ARG APT_EXTRAS=""

RUN apt-get update \
    && apt-get install -y --no-install-recommends ${GLUSTER_PACKAGES} ${APT_EXTRAS} \
    && rm -rf /var/lib/apt/lists/*

# minimal directories expected by entrypoint
RUN mkdir -p /var/lib/glusterd /bricks/brick1

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 24007 24008 49152-49251

# run with tini as simple init to reap zombies
ENTRYPOINT ["tini","--","bash","/usr/local/bin/entrypoint.sh"]