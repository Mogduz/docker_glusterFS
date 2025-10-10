
# Split-Modus: Server- und Client-Container getrennt

**Warum?**
- Kleineres Client-Image, weniger Privilegien.
- Server-Container braucht Host-Netzwerk und Brick-Bind-Mounts; Client braucht FUSE-Rechte.
- Sauberere Zuständigkeiten, einfacheres Debugging.

## Server
- läuft auf jedem Storage-Host
- braucht `network_mode: host` und Brick-Verzeichnisse als Bind-Mounts
- Ports: 24007 (mgmt), 24008, sowie Brick-Ports (typ. 49152–49251) – Firewall entsprechend öffnen

## Client
- läuft auf Konsumenten-Hosts
- braucht `/dev/fuse`, `SYS_ADMIN`, und oft `apparmor/seccomp: unconfined`
- bindet `/mnt/gluster` rshared zurück auf den Host

## Schnellstart

```bash
# Server auf JEDEM Storage-Host:
docker compose -f compose.server.split.yml build --no-cache
docker compose -f compose.server.split.yml up -d

# Volume einmalig anlegen (server-bootstrap oder händisch):
docker exec -it glusterd gluster peer probe <peername-2>
docker exec -it glusterd gluster peer probe <peername-3>
docker exec -it glusterd gluster volume create gv0 replica 3   <host1>:/bricks/brick1/gv0 <host2>:/bricks/brick1/gv0 <host3>:/bricks/brick1/gv0 force
docker exec -it glusterd gluster volume start gv0

# Client auf Konsumenten-Host:
docker compose -f compose.client.yml build --no-cache
docker compose -f compose.client.yml up -d
```

**Namensauflösung**: `gluster1`, `gluster2`, … müssen per DNS oder `/etc/hosts` auflösbar sein. Alternativ IPs verwenden.
