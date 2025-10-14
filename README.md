# GlusterFS in Docker – robustes, neustart‑sicheres Setup

Dieses Repo liefert ein **einheitliches Image** mit zwei Modi:
- `MODE=init`: Cluster/Volume anlegen (idempotent; kein Re‑Create wenn vorhanden)
- `MODE=brick`: Brick‑Knoten beitreten, Volume starten, NICHT neu anlegen

Die Skripte sind *nicht interaktiv* (`--mode=script`) und unterstützen Single‑Host‑Setups
mit mehreren Bricks **(mit `force`, wenn gewünscht)** sowie Multi‑Host‑Cluster.

---

## tl;dr – Build
```bash
docker compose -f compose.solo-2bricks-replica.yml up -d --build
```

---

## Wichtige Anforderungen
Gluster benötigt **trusted‑XATTRs** auf den Brick‑Pfaden. In Containern erlauben wir das via:
- `cap_add: [SYS_ADMIN]`
- `security_opt: ["apparmor:unconfined"]`
- Ext4/XFS mit `user_xattr` (bei ext4 Standard)

Auf besonders restriktiven Hosts ggf. `privileged: true` nutzen (nur im Lab).

---

## Beispiele

### 1) Single‑Host mit **2 Bricks** (Replica‑2, *ein* Host, *zwei* Platten)
Datei: `compose.solo-2bricks-replica.yml`

```yaml
services:
  gluster-solo:
    build: .
    image: gluster-solo-2bricks:latest
    container_name: gluster-solo
    hostname: gluster-solo
    restart: unless-stopped
    cap_add: [ "SYS_ADMIN" ]
    security_opt: [ "apparmor:unconfined" ]
    environment:
      - MODE=init
      - VOLNAME=gv0
      - VTYPE=replica
      - REPLICA=2
      - BRICK_PATHS=/bricks/brick1,/bricks/brick2
      - ALLOW_FORCE_CREATE=1     # notwendig, weil beide Bricks auf demselben Host liegen
      - REQUIRE_ALL_PEERS=0
      - ALLOW_EMPTY_STATE=1
    volumes:
      # Je Brick eine eigene physische Platte/Partition – ext4 mit XATTR
      - /mnt/disk1/gluster/brick1:/bricks/brick1
      - /mnt/disk2/gluster/brick2:/bricks/brick2
      - ./state/solo:/var/lib/glusterd
    ports:
      - "24007:24007"
      - "24008:24008"
    # Gluster-Datenports (49152-49251) nur bei Bedarf publishen
    networks: [ gluster-net ]
networks:
  gluster-net: {}
```

Start:
```bash
docker compose -f compose.solo-2bricks-replica.yml up -d --build
docker exec -it gluster-solo gluster volume info gv0
```

> Hinweis: Replica‑2 ist **Split‑Brain‑anfällig**. Für produktiv: Replica‑3 oder Arbiter.

---

### 2) Multi‑Host (3 Replika, 3 Container auf einem Host – Lab)
Datei: `compose.bricks.yml` – drei Container (`gluster1..3`) mit je einem Brick.
`gluster1` übernimmt `MODE=init` und legt `gv0` einmalig an.

```bash
docker compose -f compose.bricks.yml up -d --build
```

Prüfung:
```bash
docker exec -it gluster1 gluster peer status
docker exec -it gluster1 gluster volume info gv0
```

---

### 3) Single‑Brick (einfachstes Setup)
Datei: `compose.single-brick.yml`

```bash
docker compose -f compose.single-brick.yml up -d --build
```

---

## Umgebungsvariablen (Auszug)
- `MODE` (`brick|init`) – Startmodus
- `VOLNAME` – z. B. `gv0`
- `VTYPE` – derzeit `replica`
- `REPLICA` – Replikafaktor
- `BRICK_PATH` – Pfad für den lokalen Brick
- `BRICK_PATHS` – Kommagetrennte Liste für mehrere Bricks **auf demselben Host**
- `PEERS` – Kommagetrennte Hostnamen (1 Brick je Host)
- `ALLOW_FORCE_CREATE` – `1` erlaubt `force` bei `volume create` (z. B. Multi‑Brick auf einem Host)
- `REQUIRE_ALL_PEERS` – `1` = create nur bei allen Peers online
- `ALLOW_EMPTY_STATE` – `1` = Hinweis bei leerem `/var/lib/glusterd` unterdrücken

---

## Häufige Stolpersteine
- **Operation not permitted** beim Anlegen: fehlt oft `CAP_SYS_ADMIN` bzw. AppArmor blockt XATTR → siehe Compose‑Beispiele.
- **Replica‑2** fordert interaktiv Bestätigung → wir erzwingen Script‑Modus und steuern `force` via `ALLOW_FORCE_CREATE`.
- **Reboots**: State nach außen mounten (`/var/lib/glusterd`) – sonst vergisst glusterd sein Cluster.

---

## Lizenz
MIT
