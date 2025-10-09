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
