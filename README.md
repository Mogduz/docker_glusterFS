# GlusterFS Docker – robuste Entrypoints & Healthchecks

  Dieses Repo bringt einen gesprächigen `entrypoint.py`, der:
  - `glusterd` robust startet (probiert `-N`, `--no-daemon`, blank; oder via `GLUSTERD_BIN`),
  - falsche Binaries erkennt (Client vs Daemon) und explizit abbricht,
  - strukturierte Logs (Text/JSON) und saubere Exit-Codes liefert,
  - als `client` FUSE-Mounts idempotent managed.

  ## Wichtige ENV Variablen
  - `ROLE` = `server` | `server+bootstrap` | `client` | `noop`
  - `CONFIG_PATH` (default `/etc/gluster-container/config.yaml`)
  - `LOG_FORMAT` = `text` | `json`
  - `LOG_LEVEL`  = `DEBUG` | `INFO` | `WARN` | `ERROR`
  - `DRY_RUN`    = `1` → führt nichts aus, loggt nur
  - `GLUSTERD_BIN` = Pfad zur `glusterd`-Binary (default `/usr/sbin/glusterd`)

  ## Dockerfile Defaults
  Setzt `PATH` auf `/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin`
  und `GLUSTERD_BIN=/usr/sbin/glusterd`.

  ## Schnellstart (Server)
  ```bash
  docker run --name glusterd --rm --network host \
-e ROLE=server -e LOG_LEVEL=DEBUG \
-e GLUSTERD_BIN=/usr/sbin/glusterd \
-v /etc/glusterfs:/etc/glusterfs \
-v /var/lib/glusterd:/var/lib/glusterd \
-v /var/log/glusterfs:/var/log/glusterfs \
-v /bricks:/bricks \
gluster-hybrid
  ```

  ## Beispielkonfiguration
  Siehe `config.yaml.sample` für `server+bootstrap` und `client`.


## Troubleshooting

**Symptom:** `USAGE: glusterd [options] [mountpoint]` und Hinweise auf `--volfile-server`  
**Ursache:** Falsches Binary – das ist der *Client* (`glusterfs`), nicht der Daemon.  
**Fix:** Stelle sicher, dass **glusterfs-server** installiert ist, und dass `GLUSTERD_BIN` auf den Daemon zeigt:
```bash
dpkg -l | egrep 'glusterfs-(server|client)'
command -v glusterd; readlink -f $(command -v glusterd)
```
Starte den Container mit:
```bash
-e GLUSTERD_BIN=/usr/sbin/glusterd     -e PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
```
