# Patch-Notizen

- **BRICK_HOST**: Entrypoint nutzt Hostname (oder `HOSTNAME_GLUSTER`) statt nackter IP; falls IP == eigene IP, wird automatisch der Hostname genutzt.
- **/etc/hosts**: Hostname → Container-IP gemappt, damit glusterd den lokalen Peer korrekt erkennt.
- **Port-Range**: Datenports auf **49152–49251** begrenzt; 24007/24008 bleiben offen (Compose & Dockerfile angepasst).
- Vollständiges Repo sonst unverändert.
