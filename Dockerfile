FROM debian:12-slim

ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update       && apt-get install -y --no-install-recommends          bash tini glusterfs-server glusterfs-client procps dnsutils iproute2 util-linux       && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /var/lib/glusterd /bricks/brick1 /bricks/brick2
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 24007 24008 49152-49251
ENTRYPOINT ["/usr/bin/tini","--","/usr/local/bin/entrypoint.sh"]
