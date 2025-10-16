# GlusterFS Solo (2 Bricks Replica) — Patched

**Was wurde gefixt?**
- Der Container verwendet ab jetzt standardmäßig **den Hostnamen** (`gluster-solo`) für Brick-Endpunkte.
  Wenn `BRICK_HOST` auf die **eigene IP** zeigte, sah Gluster den lokalen Host als *nicht im Cluster* und verweigerte `volume create`.
  Das ist behoben: IP==eigene IP wird automatisch in den Hostnamen umgebogen.
- `/etc/hosts` mappt den Container-Hostname auf die Container-IPv4, damit Glusterd den lokalen Peer erkennt.
- Port-Range auf **49152–49251** begrenzt (plus 24007/24008). Passt gut zu Heimumgebungen und NAT.
- `compose.solo-2bricks-replica.yml` lässt `BRICK_HOST` leer; der Entrypoint ermittelt korrekt den Hostnamen.

**Schnellstart**
```bash
docker compose -f compose.solo-2bricks-replica.yml up -d --build
docker logs -f gluster-solo
```

**Wichtig**
- Setze `BRICK_HOST` **nicht** auf eine nackte IP des Containers.
- Wenn du die Ports auf der Gegenseite (z.B. Firewall) begrenzen willst, verwende die Range `49152–49251`.
