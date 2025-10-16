# GlusterFS Compose – Networking Fix

Dieser Patch vermeidet **Port-Kollisionen** beim Starten des Containers.
Standard-Compose veröffentlicht **keine** Ports mehr auf dem Host – damit kann
der Container immer starten.

Wenn du die Gluster-Ports nach außen publizieren willst (z. B. für andere Hosts),
verwende die Override-Datei:

```bash
docker compose -f compose.solo-2bricks-replica.yml -f compose.ports.yml up -d --build
```

Die Host-Bindings sind per `.env` steuerbar:

- `GLUSTER_PUBLISH_IP` (Default `0.0.0.0`) – Host-IP fürs Binding
- `GLUSTER_PORT_GLUSTERD` (Default `24007`)
- `GLUSTER_PORT_MGMTD` (Default `24008`)
- `GLUSTER_PORT_RANGE_START` (Default `49152`)
- `GLUSTER_PORT_RANGE_END` (Default `49251`)

Falls ein Port schon benutzt wird, setze einfach einen freien Port in der `.env`,
z. B. `GLUSTER_PORT_GLUSTERD=24017` und/oder `GLUSTER_PUBLISH_IP=127.0.0.1`.
