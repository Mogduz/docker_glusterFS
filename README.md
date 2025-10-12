# GlusterFS Docker (server-only, multi-brick, hardened v3)

Ein kompaktes Repo für ein GlusterFS-Server-Cluster mit einem Image und zwei Modi:
- `MODE=brick`: nur Brick/Server bereitstellen (kein Create)
- `MODE=init`: Brick + Cluster-/Volume-Initialisierung (idempotent)

**Features**
- Sauberes PID1 via `tini`, strukturierte Logs (STEP/INFO/WARN/ERROR/OK)
- Auto-Detection (`VOLNAME=auto`) → Brick-only, wenn kein Volume sichtbar
- Konfigurierbare Peer-Warte-Strategie (`PEER_WAIT_SECS`, `PEER_WAIT_INTERVAL`)
- **Multi-Brick pro Container** via `BRICK_PATHS=/bricks/brick1,/bricks/brick2,...`
- DRY-RUN-Modus zum Validieren der Kommandofolge (`DRY_RUN=1`)
- Feste Port-Range, optional IPv4/IPv6, Heal/Health-Checks

## Schnellstart (3-Node-Cluster, 2 Bricks/Host)
```bash
docker compose -f compose.bricks.yml up -d --build
docker exec -it gluster1 gluster peer status
docker exec -it gluster1 gluster volume info gv0
```

## Nur Brick (kein Create, Autodetektion)
```bash
docker compose -f compose.brick-only.yml up -d --build
docker logs -f gluster-brick
```

## Mehrere Bricks pro Container
Setze mehrere Pfade per `BRICK_PATHS` (Komma-separiert). Beispiel (ein Container, zwei Bricks auf demselben Host):
```yaml
services:
  gluster1:
    environment:
      - MODE=init
      - VOLNAME=gv0
      - REPLICA=3
      - BRICK_PATHS=/bricks/brick1,/bricks/brick2
      - PEERS=gluster1,gluster2,gluster3
    volumes:
      - ./data/gluster1/brick1:/bricks/brick1
      - ./data/gluster1/brick2:/bricks/brick2
      - ./state/gluster1:/var/lib/glusterd
```
**Create-Logik:** Die Bricks werden in der Reihenfolge „für jeden Pfad alle Peers“ übergeben, sodass bei `replica=N` korrekte Sätze entstehen. Gesamtzahl der Bricks muss ein Vielfaches von `REPLICA` (bzw. von `DISPERSE+REDUNDANCY`) sein.
**Brick-Join (MODE=brick):** Automatisches `add-brick` nur bei `REPLICA=1`. Für Replikate nutze `ADD_BRICK_SET` (Liste von Hosts); pro Pfad wird dann ein kompletter Satz hinzugefügt.

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
- `BRICK_PATHS` – eine oder mehrere Brick-Pfade (Komma-separiert)
- `DRY_RUN` – `1` = Gluster-Kommandos nur loggen (Validierung/Tests)
- `ADDRESS_FAMILY` – `inet` (IPv4) oder `inet6`
- `PORT_RANGE` – z. B. `49152-49251`
- `ALLOW_FORCE_CREATE` – `0` (Default); nur bewusst aktivieren
- `AUTO_ADD_BRICK` / `ADD_BRICK_SET` – vorsichtige Brick-Erweiterung (siehe oben)

## Lizenz
MIT


## Beispiel: 1 Server, 2 Platten – Replica‑2 mit bestehenden ext4‑Ordnern

Dieses Beispiel spiegelt Daten **auf zwei Platten desselben Hosts**, indem ein Container mit **zwei Bricks** (je Brick ein Ordner auf je einer Platte) im **Replica‑2**‑Modus läuft. Die Ordner liegen auf bereits vorhandenen ext4‑Dateisystemen—es werden **nur Verzeichnisse** genutzt, keine Rohgeräte.

### 0) Ordner auf vorhandenen ext4‑Platten (Beispielpfade)
```bash
# Beispiel: Platten sind bereits als ext4 gemountet
sudo mkdir -p /mnt/disk1/gluster/brick1 /mnt/disk2/gluster/brick2
```

### 1) Compose: ein Container, zwei Bricks, Replica=2
Erstelle `compose.solo-2bricks-replica.yml`:
```yaml
version: "3.9"
services:
  gluster-solo:
    build: .
    container_name: gluster-solo
    hostname: gluster-solo
    restart: unless-stopped
    environment:
      - MODE=init                 # legt das Volume an (falls nicht vorhanden)
      - VOLNAME=gv0
      - VTYPE=replica
      - REPLICA=2                 # Spiegelung über beide Bricks/Platten
      - BRICK_PATHS=/bricks/brick1,/bricks/brick2
      - PEERS=gluster-solo        # nur dieser Host
      - REQUIRE_ALL_PEERS=1
      - ADDRESS_FAMILY=inet
      - PORT_RANGE=49152-49251
      - LOG_LEVEL=INFO
      - PEER_WAIT_SECS=0          # kein Warten nötig (Single-Host)
      # Optionaler Sicherheitsgurt, wenn echte Mountpoints erzwungen werden sollen:
      # - REQUIRE_MOUNTED_BRICK=1
    volumes:
      - /mnt/disk1/gluster/brick1:/bricks/brick1
      - /mnt/disk2/gluster/brick2:/bricks/brick2
      - ./state:/var/lib/glusterd
    ulimits:
      nofile:
        soft: 65536
        hard: 65536
    healthcheck:
      test: ["CMD-SHELL", "pgrep -x glusterd >/dev/null && gluster volume info gv0 >/dev/null 2>&1"]
      interval: 10s
      timeout: 5s
      retries: 20
```

**Starten & prüfen:**
```bash
docker compose -f compose.solo-2bricks-replica.yml up -d --build
docker exec -it gluster-solo gluster volume info gv0
docker exec -it gluster-solo gluster volume status gv0
```

### 2) Day‑2‑Betrieb
Du **musst** `MODE=init` nicht entfernen—der EntryPoint ist idempotent und erstellt kein Volume neu. 
Empfohlen ist dennoch, nach der Erstinitialisierung auf **`MODE=brick`** umzuschalten (serve‑only):

```yaml
# compose.solo-2bricks-replica.yml – steady state
environment:
  - MODE=brick
  - VOLNAME=gv0
  - VTYPE=replica
  - REPLICA=2
  - BRICK_PATHS=/bricks/brick1,/bricks/brick2
  - PEERS=gluster-solo
```

**Übernehmen:**
```bash
docker compose -f compose.solo-2bricks-replica.yml up -d
```

### Hinweise
- **Redundanz:** Replica‑2 spiegelt auf **zwei Platten desselben Hosts**. Das schützt vor Plattenausfall, aber **nicht** vor Host‑Ausfall. Für Host‑Redundanz: später erweitern (z. B. `replica 3` oder `replica 3 arbiter 1`).
- **Validierung ohne Änderungen:** `DRY_RUN=1` zeigt alle `gluster`‑Kommandos nur im Log.
- **Mount‑Sicherheit:** `REQUIRE_MOUNTED_BRICK=1` erzwingt echte Mountpoints für jeweils unterschiedliche Geräte/Filesysteme.


> **Hinweis (Compose v2):** Die Top‑Level‑Angabe `version:` ist obsolet und wurde aus den Compose‑Dateien entfernt, um die Warnung von Docker Compose zu vermeiden.

**Single‑Host, 2 Bricks (Replica‑2):** Siehe `compose.solo-2bricks-replica.yml` – entspricht dem Beispiel im Abschnitt *1 Server, 2 Platten*.


### Single-Host Replica‑2 (2 Bricks auf einem Server)
Gluster blockiert Replica‑Volumes mit **mehreren Bricks auf demselben Host**, außer man bestätigt bewusst. Unser Entrypoint setzt daher bei Bedarf **`--mode=script`** und du aktivierst den Override per ENV:
- Setze in `compose.solo-2bricks-replica.yml`: `ALLOW_FORCE_CREATE=1`
- Für einen Single‑Host: `PEERS=` (leer), damit keine Peer‑Probes/Pool‑Parses laufen

So wird ausgeführt:

```
gluster --mode=script volume create gv0 replica 2 \
  gluster-solo:/bricks/brick1 gluster-solo:/bricks/brick2 force
gluster --mode=script volume start gv0
```

Nach der Initialisierung kannst du mit `compose.solo-2bricks-replica.steady.yml` im `MODE=brick` weiterfahren.
