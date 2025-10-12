# GlusterFS Docker (server-only, hardened v3)

Ein kompaktes Repo für ein GlusterFS-Server-Cluster mit einem Image und zwei Modi:
- `MODE=brick`: nur Brick/Server bereitstellen (kein Create)
- `MODE=init`: Brick + Cluster-/Volume-Initialisierung (idempotent)

**Features**
- Sauberes PID1 via `tini`, strukturierte Logs (STEP/INFO/WARN/ERROR/OK)
- Auto-Detection (`VOLNAME=auto`) → Brick-only, wenn kein Volume sichtbar
- Konfigurierbare Peer-Warte-Strategie (`PEER_WAIT_SECS`, `PEER_WAIT_INTERVAL`)
- Feste Port-Range, optional IPv4/IPv6, Heal/Health-Checks
- Volumentypen: `replica` oder `disperse` (per ENV)

## Schnellstart (3-Node-Cluster)
```bash
docker compose -f compose.bricks.yml up -d --build
docker exec -it gluster1 gluster peer status
docker exec -it gluster1 gluster volume info gv0
```

## Nur Brick (kein Create)
```bash
docker compose -f compose.brick-only.yml up -d --build
docker logs -f gluster-brick
```

## Debug-Modus
Für sehr ausführliche Logs (Shell-Trace, INFO-Level) nutze die Overrides:

**Cluster (3 Nodes):**
```bash
docker compose -f compose.bricks.yml -f compose.debug.bricks.yml up -d --build
```

**Nur Brick:**
```bash
docker compose -f compose.brick-only.yml -f compose.debug.brick-only.yml up -d --build
```

Diese Overrides setzen `TRACE=1`, `LOG_LEVEL=INFO` und warten mit `PEER_WAIT_SECS=-1` unendlich auf das Quorum (Intervall 2s).

## Wichtige ENV-Variablen
- `MODE` (`brick|init`) – Rolle des Containers
- `VOLNAME` – z. B. `gv0` oder `auto` (Autodetektion)
- `VTYPE` (`replica|disperse`) – Volumentyp
- `REPLICA` – Replikafaktor (bei `replica`)
- `DISPERSE` / `REDUNDANCY` – Parameter für `disperse`
- `PEERS` – Kommagetrennte Hostnamen (DNS im Docker-Netz)
- `REQUIRE_ALL_PEERS` – `1` (Default) = sichere Volume-Erstellung nur bei vollem Quorum
- `PEER_WAIT_SECS` – `-1`=unendlich, `0`=nicht warten, `>0`=Sekunden (Default `120`)
- `PEER_WAIT_INTERVAL` – Abfrageintervall in Sekunden (Default `1`)
- `ADDRESS_FAMILY` – `inet` (IPv4) oder `inet6`
- `PORT_RANGE` – z. B. `49152-49251`
- `ALLOW_FORCE_CREATE` – `0` (Default); nur bewusst aktivieren
- `AUTO_ADD_BRICK` / `ADD_BRICK_SET` – vorsichtige Brick-Erweiterung (Hinweise im Script)

## Ordner
- `data/*` – Brick-Daten (bind-mount)
- `state/*` – Gluster State (`/var/lib/glusterd`)
- `.gitkeep` hält die Struktur im Repo.

## Lizenz
MIT
