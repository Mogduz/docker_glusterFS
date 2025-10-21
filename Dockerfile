# Minimal Beispiel-Dockerfile für GlusterFS + hybriden Entrypoint
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \        glusterfs-server \        python3 python3-venv python3-pip \        tini bash ca-certificates \        && rm -rf /var/lib/apt/lists/*

# Python deps
RUN pip3 install --no-cache-dir pyyaml

# Verzeichnisse
RUN mkdir -p /etc/gluster /var/lib/glusterd /bricks /entrypoints

# Skripte
COPY entrypoints/ /entrypoints/
RUN chmod +x /entrypoints/entrypoint.hybrid.sh /entrypoints/solo-startup.py

# Exponierte Ports (GlusterD + Brick-Ports)
EXPOSE 24007 24008 49152-49251

# Tini als PID1, Bash-Entrypoint kümmert sich um Glusterd und Solo-Startup
ENTRYPOINT ["/usr/bin/tini","-g","--","/entrypoints/entrypoint.hybrid.sh"]
CMD ["glusterd","-N"]
