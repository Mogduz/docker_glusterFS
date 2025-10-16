# Fix: Host is not in 'Peer in Cluster' state

Bei Single-Node-Setups darf in den Brick-Pfaden **nicht** die nackte IP stehen,
sonst interpretiert Gluster das als *anderen* Peer. Der Entrypoint setzt deshalb
den Hostnamen automatisch (FQDN/Shortname), auch wenn `BRICK_HOST` eine IP ist.

**Was wurde geändert?**
- `entrypoint.sh`: automatische Hostnamen-Auflösung und `/etc/hosts`-Absicherung.
- `compose.solo-2bricks-replica.yml`/`.env`: kein hartes `BRICK_HOST=<IP>` mehr.

**Starten:**
```bash
docker compose -f compose.solo-2bricks-replica.yml up -d --build
docker logs -f gluster-solo
```
Du solltest nun eine Zeile sehen wie:
```
[INFO] resolved local BRICK_HOST=<dein-hostname>
[INFO] creating: gluster volume create gv0 replica 2 transport tcp <host>:/bricks/brick1 <host>:/bricks/brick2 force
```
