# GlusterFS Docker (hardened v3)

Ein kompaktes Repo, um ein GlusterFS-Cluster mit **einem Image, zwei Modi** zu betreiben:
- `MODE=brick`: nur Brick/Server bereitstellen
- `MODE=init`: Brick + Cluster- und Volume-Initialisierung

**Highlights**
- Sauberes PID1 via `tini` (keine Zombieprozesse, saubere Signale)
- Neustart-sicher & idempotent
- Feste Port-Range, optionale IPv4/IPv6, Heal/Health-Checks
- Volumentypen: `replica` oder `disperse`

## Schnellstart
```bash
docker compose -f compose.bricks.yml up -d --build
docker exec -it gluster1 gluster peer status
docker exec -it gluster1 gluster volume info gv0
```

## Wichtige ENV-Variablen
- `MODE` (`brick|init`) – Rolle des Containers
- `VOLNAME` – z. B. `gv0`
- `VTYPE` (`replica|disperse`) – Volumentyp
- `REPLICA` – Replikafaktor (bei `replica`)
- `DISPERSE` / `REDUNDANCY` – Parameter für `disperse`
- `PEERS` – Kommagetrennte Hostnamen (DNS im Docker-Netz)
- `ADDRESS_FAMILY` – `inet` (IPv4) oder `inet6`
- `PORT_RANGE` – z. B. `49152-49251`
- `REQUIRE_ALL_PEERS` – `1` (Default) = sichere Volume-Erstellung nur bei vollem Quorum
- `ALLOW_FORCE_CREATE` – `0` (Default); nur bewusst aktivieren
- `AUTO_ADD_BRICK` / `ADD_BRICK_SET` – vorsichtige Brick-Erweiterung (Hinweise im Script)

## Ordner
- `data/*` – Brick-Daten (bind-mount)
- `state/*` – Gluster State (`/var/lib/glusterd`)
- Platzhalter `.gitkeep` halten die Struktur im Repo.

## Sicherheit & Betrieb
- Zeit-Synchronisation auf Hosts (chrony/NTP) ist Pflicht.
- Bei SELinux: Bind-Mounts ggf. mit `:z` labeln.
- TLS optional via `ENABLE_SSL=1` (Zertifikate bereitstellen).

## Lizenz
MIT
