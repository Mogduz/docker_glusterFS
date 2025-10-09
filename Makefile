# -----------------------------------------------------------------------------
# Developer conveniences for building the image and bringing up demo stacks.
# Adjust IMAGE to point to your registry namespace.
# -----------------------------------------------------------------------------
IMAGE ?= ghcr.io/yourorg/glusterfs-hybrid:ubuntu24

.PHONY: build server-up server-down client-up client-down logs

build:
	# Build the GlusterFS hybrid image
\tdocker build -t $(IMAGE) .

server-up:
	# Start the Gluster server on the local host
\tdocker compose -f compose.server.yml up -d

server-down:
	# Stop the Gluster server stack
\tdocker compose -f compose.server.yml down

client-up:
	# Start the Gluster client
\tdocker compose -f compose.client.yml up -d

client-down:
	# Stop the Gluster client
\tdocker compose -f compose.client.yml down

logs:
	# Tail logs from both server and client containers (ignore missing)
\tdocker logs -f glusterd || true; docker logs -f gluster-client || true
