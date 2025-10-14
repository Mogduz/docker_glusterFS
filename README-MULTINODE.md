# Mehr-Node-Setups (Replica-2, Replica-3, Arbiter)

Diese Compose-Dateien starten **nur den Gluster-Server** pro Node (kein Autocreate des Volumes).
Danach erledigst du Peer/Volume-Schritte manuell oder via Skripts in `scripts/`.

## 0) Voraussetzungen
- Ports öffnen: **24007/24008** + **je Brick ein Port ab 49152** (IANA-Ephemeral). Siehe Gluster-Doku. 
- Hostnames/IPs müssen gegenseitig auflösbar sein.

## 1) Start auf jedem Node
Wähle die passende Compose-Datei:
- `compose.2nodes-replica2.yml` (je Node **1 Brick**)
- `compose.3nodes-replica3.yml` (je Node **1 Brick**)
- `compose.3nodes-arbiter.yml` (je Node **1 Brick**, ein Node dient als Arbiter)

Setze auf **jedem Node** in `.env` mindestens:
```env
BRICK_HOST=<dieserNodeHostnameOderIP>
HOST_BRICK1=<lokaler Pfad für Brick1, z. B. /mnt/disk1/brick1>
```
Dann:
```bash
docker compose -f compose.2nodes-replica2.yml up -d    # bzw. die passende Datei
```

## 2) Trusted Pool
Auf einem Node (z. B. dem ersten) Peers hinzufügen:
```bash
docker exec -it gluster bash -lc './scripts/peer-probe.sh node2 [node3]'
# oder manuell:
# gluster peer probe node2
# gluster peer probe node3
# gluster peer status
```

## 3) Volume anlegen
**Replica-2 (2 Nodes):**
```bash
docker exec -it gluster bash -lc './scripts/volume-create-replica2.sh gv0 node1 node2 /bricks/brick1'
```

**Replica-3 (3 Nodes):**
```bash
docker exec -it gluster bash -lc './scripts/volume-create-replica3.sh gv0 node1 node2 node3 /bricks/brick1'
```

**Arbiter (3 Nodes, replica 3 arbiter 1):**
```bash
docker exec -it gluster bash -lc './scripts/volume-create-arbiter.sh gv0 node1 node2 node3 /bricks/brick1'
```

Danach kannst du auf Clients mounten, z. B.:
```bash
mount -t glusterfs node1:/gv0 /mnt/gluster
```

## Quellen
- Quickstart & Peer-Probe/Volume-Create: Gluster-Doku.
- Ports/Firewall: Gluster Administrator Guide.
- Arbiter-Volumes: Gluster Administrator Guide.
- Disperse/Dispersed Volumes: Gluster Docs / Red Hat Docs.

