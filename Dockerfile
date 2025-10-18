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

# GlusterFS Server – minimal, server-only
FROM debian:12-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      glusterfs-server tini ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# Documented ports (publish via compose/run)
EXPOSE 24007 24008 49152-49251
COPY entrypoints/entrypoint.sh /usr/local/bin/entrypoint.sh

COPY entrypoints/*.sh /usr/local/bin/
COPY *.sh /
RUN chmod +x /*.sh
RUN chmod +x /usr/local/bin/*.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Run glusterd in foreground (-N) under tini for proper signal handling
ENTRYPOINT ["/usr/bin/tini","--","/usr/local/bin/entrypoint.sh"]