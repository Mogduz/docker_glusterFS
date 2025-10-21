# === [DOC] Autogenerierte Inline-Dokumentation: Dockerfile ===
# Datei: Dockerfile
# Typ: Dockerfile zum Build des GlusterFS-Server-Images.
# Basis-Image: debian:12-slim
# Exponierte Ports: 24007 24008 49152-49251
# Kopierte Dateien/Verzeichnisse:
#   - entrypoints/entrypoint.sh /usr/local/bin/entrypoint.sh
#   - entrypoints/*.sh /usr/local/bin/
#   - *.sh /
# ENTRYPOINT: ["/usr/bin/tini","--","/usr/local/bin/entrypoint.sh"]
# Hinweis: Kommentare beschreiben Build-Schritte, Pfade und Berechtigungen.
# === [DOC-END] ===
# Base image pulled from a Docker Hub mirror to avoid 503 auth outages; override with --build-arg BASE_IMAGE=debian:12-slim if needed.

# GlusterFS Server – minimal, server-only
ARG BASE_IMAGE=mirror.gcr.io/library/debian:12-slim
FROM ${BASE_IMAGE}
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \ python3 \ python3-yaml \
      glusterfs-server tini ca-certificates yq \
 && rm -rf /var/lib/apt/lists/*

# Documented ports (publish via compose/run)
EXPOSE 24007 24008 49152-49251

COPY entrypoints/*.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/*.py
COPY entrypoints/*.py /usr/local/bin/
RUN chmod +x /usr/local/bin/*.sh

# Run glusterd in foreground (-N) under tini for proper signal handling
ENTRYPOINT ["/usr/bin/tini","--","/usr/local/bin/entrypoint.sh"]