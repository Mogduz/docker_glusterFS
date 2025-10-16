# GlusterFS Solo (2 Bricks) — Fixed

This bundle fixes the `starting` hang by:
- Running `glusterd` **in the foreground** (`-N`), no systemd needed.
- Using **host networking** so all Gluster ports are reachable.
- Adding **privileged + /dev/fuse + SYS_ADMIN** only if you decide to do FUSE mounts inside the container (not required just to run `glusterd`).
- A **healthcheck** that only pings the daemon; no mounts needed.
- Optional auto-create of a *replica-2* volume (`gv0`) on two local bricks in the same node (**uses `force`**).

## Quick start

```bash
# from this folder
docker compose build
docker compose up -d
# check:
docker ps
docker logs -f gluster-solo
gluster --mode=script volume info gv0
```

Mount from a client node (Linux):
```bash
sudo apt-get install glusterfs-client   # or your distro equivalent
sudo mkdir -p /mnt/gluster
sudo mount -t glusterfs gluster-solo:/gv0 /mnt/gluster
```

## Notes

- If you don't plan to issue *mounts* from inside the container, `/dev/fuse` and `SYS_ADMIN` are not strictly required, but they do no harm here.
- `docker-compose.yml` intentionally **omits** the obsolete top-level `version` key (Compose v2 ignores it).
- Ports used by Gluster: `24007`, `24008`, and **one port per brick starting at 49152** (hence host networking to avoid mapping the range).


### Hinweis zu `Host <name> is not in 'Peer in Cluster' state`
Wenn die Volume-Erstellung mit dieser Meldung scheitert, liegt es fast immer an **Namensauflösung/Peer-Name-Mismatch**.
Das Compose/Entrypoint nutzt jetzt standardmäßig **BRICK_HOST=localhost**, womit die Einträge `localhost:/bricks/...` verwendet werden.
Damit entfällt die Notwendigkeit, dass der Hostname des Containers exakt dem **Peer-Namen** im Gluster-Pool entspricht.
Alternativ kannst du `BRICK_HOST=<IP oder FQDN>` setzen – aber stelle dann sicher, dass der Name/IP im Container auflösbar ist
(z. B. via `/etc/hosts`).



## Bind Mounts aus `.env` (wichtig)
Die Brick-Verzeichnisse auf dem **Host** werden nun *ausschließlich* aus `.env` gelesen:

```env
HOST_BRICK1=/mnt/disk1/brick1
HOST_BRICK2=/mnt/disk2/brick2
```

Im Compose werden diese so eingebunden:
```yaml
volumes:
  - ${HOST_BRICK1:?set HOST_BRICK1 in .env}:/bricks/brick1:rw
  - ${HOST_BRICK2:?set HOST_BRICK2 in .env}:/bricks/brick2:rw
```

Fehlt eine Variable, bricht `docker compose` mit einer klaren Meldung ab (kein heimliches Anlegen von Default-Pfaden).


## Dynamische Brick-Zahl
Setze in `.env` beliebig viele Host-Pfade – entweder nummeriert **HOST_BRICK1..N** oder als Liste **HOST_BRICK_PATHS**:

```env
HOST_BRICK1=/mnt/disk1/brick1
HOST_BRICK2=/mnt/disk2/brick2
HOST_BRICK3=/mnt/disk3/brick3
# ...
# alternativ:
# HOST_BRICK_PATHS=/mnt/disk1/brick1,/mnt/disk2/brick2,/mnt/disk3/brick3
```

Generiere dann das Override (wird automatisch von Compose geladen):
```bash
python3 scripts/gen-compose-override.py
docker compose up -d
```

Der Entrypoint liest `BRICK_PATHS` (Container-Pfade) und erstellt das Volume dynamisch. Bei `REPLICA=2` muss die Brick-Anzahl ein **Vielfaches von 2** sein (distributed-replicated).


### Wichtig: `localhost` wird von Gluster für Bricks abgelehnt
Gluster verweigert `localhost`/Loopback-Adressen beim `volume create` für Bricks. Verwende eine **nicht-loopback** IPv4/FQDN deines Hosts (`BRICK_HOST`), oder setze `PRIVATE_IP`. Der Entrypoint ermittelt sonst automatisch die erste globale IPv4. Siehe auch Gluster CLI-Parser, der `localhost/127.0.0.1` explizit ablehnt, und Mailinglisten-Beiträge mit identischer Fehlermeldung.

### Brick-Ports / Range
Wir setzen standardmäßig `base-port=${DATA_PORT_START:-49152}` und `max-port 49251}` in `/etc/glusterfs/glusterd.vol`. Öffne in Firewalls die **24007/24008** sowie **je Brick einen Port** in dieser Range. Logs zeigen beim Start die übernommene `max-port`-Einstellung.


### `BRICK_HOST` vs. `PRIVATE_IP`
Der Container bekommt jetzt `PRIVATE_IP` aus `.env` explizit injiziert. Die Host-Ermittlung im Entrypoint läuft so:
1. Wenn `BRICK_HOST` gesetzt **und** nicht-Loopback → verwenden.
2. Sonst, wenn `PRIVATE_IP` gesetzt **und** nicht-Loopback → verwenden.
3. Sonst automatische Erkennung der ersten globalen IPv4.



**Hinweis:** Für Solo-Deployments ist `BRICK_HOST=<Container-Hostname>` (z. B. `gluster-solo`) am robustesten. Der Entrypoint mappt diesen Hostnamen intern auf die Container-IP (kein Loopback), damit Gluster ihn als lokalen Peer akzeptiert.
