# GlusterFS Docker – Hybrider Entrypoint (Bash + Python)

Dieses Repo enthält ein hybrides Entrypoint-Setup:

- **Bash** (`entrypoints/entrypoint.hybrid.sh`) kümmert sich um Prozess-Lifecycle (PID1 via `tini`), startet `glusterd`, wartet auf CLI-Bereitschaft und triggert bei Bedarf das Solo-Bootstrapping.
- **Python** (`entrypoints/solo-startup.py`) liest `/etc/gluster/volumes.yml` (per Compose-Bind-Mount bereitgestellt) mit PyYAML und erstellt/konfiguriert Volumes über `gluster`-CLI (`subprocess`).

## Compose
Siehe `compose/compose.solo-2bricks-replica.yml`. Relevante Variablen in `.env.example`.

## Solo-Trigger (Bedingungen)
- `SOLO_STARTUP=on` erzwingt Bootstrapping.
- `SOLO_STARTUP=off` deaktiviert Bootstrapping.
- `SOLO_STARTUP=auto` (Default) triggert, **wenn** `VOLUMES_YML` existiert und nicht leer ist (Default: `/etc/gluster/volumes.yml`).

## YAML-Schema (`/etc/gluster/volumes.yml`)
```yamlyaml
volumes:
  - name: gv0
    bricks:
      - /bricks/brick1/gv0
      - /bricks/brick2/gv0
    replica: 2
    transport: tcp
    options:
      nfs.disable: "on"
      performance.quick-read: "on"
```

## Build & Start (Beispiel)
```bash
cp .env.example compose/.env
docker compose -f compose/compose.solo-2bricks-replica.yml up --build
```

## Hinweise
- Das Dockerfile nutzt **Debian Bookworm** und installiert `glusterfs-server`. Je nach Plattform können Paketquellen variieren.
- Der Entrypoint startet `glusterd` im Hintergrund, führt `solo-startup.py` aus und wartet anschließend auf `glusterd`.
- Healthcheck nutzt `gluster volume list`.
- Brick-Verzeichnisse werden über Compose-Variablen gemountet (siehe `.env.example`).
