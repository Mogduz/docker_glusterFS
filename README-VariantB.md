# Variant B – Server (Ports published + Firewall nur für 10.*)

## 0) .env anlegen
```
cp .env.example .env
# trage deine Werte ein:
# PRIVATE_IP=10.0.0.10
# PRIVATE_CIDR=10.0.0.0/24
```

## 1) Server starten
```
docker compose -f compose.server.variantB.yml up -d --build
docker compose -f compose.server.variantB.yml logs -f gluster-solo
```

## 2) Host-Firewall setzen (Docker-sicher)
```
cd scripts
PRIVATE_CIDR=$(grep '^PRIVATE_CIDR=' ../.env | cut -d= -f2) ./gluster-firewall-variant-b.sh apply
# Persistenz (optional):
apt-get install -y netfilter-persistent && netfilter-persistent save
```

Status/Remove:
```
./gluster-firewall-variant-b.sh status
./gluster-firewall-variant-b.sh remove
```

## 3) Gluster Allowlist (App-Schicht)
```
cd scripts
PRIVATE_CIDR=$(grep '^PRIVATE_CIDR=' ../.env | cut -d= -f2) ./gluster-variant-b-postdeploy.sh
```

## 4) Checks
```
docker exec -it gluster-solo gluster volume info
docker exec -it gluster-solo gluster volume status
```

## Hinweise
- `extra_hosts` setzt `gluster-solo` → `${PRIVATE_IP}`, damit Volfiles/Bricks auf 10.* zeigen.
- Client-Mount: `mount -t glusterfs ${PRIVATE_IP}:/gv0 /mnt/glusterfs`
- Bei mehr Clients/Servern CIDR entsprechend weiter fassen.

---

## Schnell mit Script (liest `.env`)
```bash
cd scripts
# zeigt erkannte Werte (PRIVATE_IP/CIDR, PUBLIC_IF, Bridge etc.)
./firewall-from-env.sh detect
# Regeln setzen
sudo ./firewall-from-env.sh apply
# Status/Rückbau
sudo ./firewall-from-env.sh status
sudo ./firewall-from-env.sh remove
```

### Variablen in `.env` für Port-Mapping (Compose)
- `MGMT_PORT1` (default 24007)
- `MGMT_PORT2` (default 24008)
- `DATA_PORT_START`–`DATA_PORT_END` (default 49152–49251)

Compose liest `.env` automatisch, die Ports werden an `${PRIVATE_IP}` gebunden:
```yaml
ports:
  - "${PRIVATE_IP}:${MGMT_PORT1}:${MGMT_PORT1}/tcp"
  - "${PRIVATE_IP}:${MGMT_PORT2}:${MGMT_PORT2}/tcp"
  - "${PRIVATE_IP}:${DATA_PORT_START}-${DATA_PORT_END}:${DATA_PORT_START}-${DATA_PORT_END}/tcp"
```

### Weitere `.env` Variablen
Gluster/Runtime:
```
MODE=init
VTYPE=replica
REPLICA=2
VOLNAME=gv0
BRICK_PATHS=/bricks/brick1,/bricks/brick2
ALLOW_EMPTY_STATE=1
ALLOW_FORCE_CREATE=1
LOG_LEVEL=INFO
```

Compose/Container:
```
CONTAINER_NAME=gluster-solo
HOSTNAME_GLUSTER=gluster-solo
RESTART_POLICY=unless-stopped
HC_INTERVAL=5s
HC_TIMEOUT=3s
HC_RETRIES=30
HC_START_PERIOD=10s
```
Die Werte werden direkt von `compose.server.variantB.yml` konsumiert (environment, healthcheck, restart, container_name, hostname).

### Noch feiner per `.env`
Glusterd:
- `ADDRESS_FAMILY` (inet|inet6) – steuert `glusterd.vol`
- `MAX_PORT` – oberer Port, den glusterd nutzen darf
- `TRANSPORT` (tcp|rdma) – für `volume create ... transport`

Volume-Optionen:
- `VOL_OPTS` – kommasepariert `key=value`, z. B. `network.ping-timeout=5,performance.client-io-threads=on`
- `NFS_DISABLE=1` – setzt `nfs.disable on`

Ressourcenlimits (Compose):
- `CPUS=1.0`, `MEM_LIMIT=1g`

Bind-Mount-Override (optional):
```
docker compose -f compose.server.variantB.yml -f compose.server.variantB.bind.yml up -d
```
Setze Pfade in `.env`:
```
BRICKS_HOST_ROOT=/srv/gluster/bricks
VARLIB_HOST=/srv/gluster/varlib
LOGS_HOST=/srv/gluster/logs
```
