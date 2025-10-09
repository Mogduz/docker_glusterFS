IMAGE ?= ghcr.io/yourorg/glusterfs-hybrid:ubuntu24

.PHONY: build server-up server-down client-up client-down logs

build:
\tdocker build -t $(IMAGE) .

server-up:
\tdocker compose -f compose.server.yml up -d

server-down:
\tdocker compose -f compose.server.yml down

client-up:
\tdocker compose -f compose.client.yml up -d

client-down:
\tdocker compose -f compose.client.yml down

logs:
\tdocker logs -f glusterd || true; docker logs -f gluster-client || true
