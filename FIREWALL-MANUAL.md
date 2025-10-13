# Firewall (manuell, ohne Docker-spezifische Chains)

Du möchtest die Regeln **selbst** setzen und **Docker aus der Gleichung lassen**. Geht – beachte aber:
Docker veröffentlicht Port-Mappings via DNAT/Forwarding. Regeln im `INPUT`-Chain allein reichen nicht immer.
Die folgenden Varianten sind **rein hostseitige iptables-Regeln**, ohne `DOCKER-USER` o. ä.

## 0) Voraussetzung
In `compose.server.variantB.yml` werden Ports **an die private Host-IP** gebunden (z. B. `${PRIVATE_IP}=10.0.0.10`).
Damit lauscht der Host **nicht** auf der Public-IP für diese Ports.

## 1) Minimaler Schutz auf der Public-NIC (INPUT)
Blocke alle Gluster-Ports auf der **öffentlichen** Schnittstelle (ersetze `eth0` durch deine Public-NIC):
```bash
PUB_IF=eth0
iptables -A INPUT -i "$PUB_IF" -p tcp -m multiport --dports 24007,24008 -j REJECT
iptables -A INPUT -i "$PUB_IF" -p tcp --dport 49152:49251 -j REJECT
```
*Diese Regeln schützen vor versehentlichem Port-Bind an der Public-IP.*

## 2) Strikter Forward-Filter (für DNAT → Container)
Traffic zu den veröffentlichten Container-Ports wird per DNAT weitergeleitet und landet im `FORWARD`-Pfad.
Wir erlauben **nur** 10.0.0.0/24 und verwerfen den Rest – ganz ohne Docker-Chains.

### 2.1 Docker-Bridge/Subnetz ermitteln
Ermittle die Bridge & das Subnetz deines Compose-Netzes (Beispiel-Name anpassen):
```bash
NET_NAME=$(docker network ls --format '{{.Name}}' | grep -E '^.*_default$' | head -n1)
BR_IF=$(docker network inspect "$NET_NAME" -f '{{index .Options "com.docker.network.bridge.name"}}')
SUBNET=$(docker network inspect "$NET_NAME" -f '{{(index .IPAM.Config 0).Subnet}}')
echo "NET=$NET_NAME  BR_IF=$BR_IF  SUBNET=$SUBNET"
```
> Falls `BR_IF` leer ist, heißt das Interface meist `br-<network-id>`. Ermitteln mit: `ip -br link | grep br-`

### 2.2 Regeln setzen (FORWARD)
```bash
PRIVATE_CIDR=10.0.0.0/24
# Erlauben: aus PRIVATE_CIDR in Richtung Container-Bridge auf Gluster-Ports
iptables -I FORWARD -p tcp -m multiport --dports 24007,24008 -s "$PRIVATE_CIDR" -o "$BR_IF" -j ACCEPT
iptables -I FORWARD -p tcp --dport 49152:49251          -s "$PRIVATE_CIDR" -o "$BR_IF" -j ACCEPT

# Verbieten: alle anderen Quellen in Richtung Container-Bridge auf Gluster-Ports
iptables -A FORWARD -p tcp -m multiport --dports 24007,24008 -o "$BR_IF" -j REJECT
iptables -A FORWARD -p tcp --dport 49152:49251          -o "$BR_IF" -j REJECT
```

> Reihenfolge ist wichtig: wir **inserten** die ALLOWs (mit `-I`) vor die späteren REJECTs.

## 3) Persistenz
Auf Debian/Ubuntu:
```bash
apt-get install -y netfilter-persistent
netfilter-persistent save
```

## 4) Tests
```bash
# Von einem 10er-Host:
nc -vz ${PRIVATE_IP} 24007     # sollte "succeeded" zeigen
# Von einem Nicht-10er-Host:
nc -vz <PUBLIC_IP> 24007       # sollte "refused/timeout"
```

## 5) Bonus – App-Schicht-Whitelist
Auch Gluster selbst nur 10er erlauben:
```bash
docker exec -it gluster-solo gluster volume set gv0 auth.allow 10.0.0.*
docker exec -it gluster-solo gluster volume get gv0 auth.allow
```

---
**Hinweis:** Docker kann bei Upgrades/Neustarts eigene Regeln in `FORWARD/NAT` ergänzen. Die obigen Regeln greifen dennoch, solange sie **vor** generischen ACCEPTs stehen. Falls Docker die Reihenfolge ändert, einfach die ALLOWs wieder mit `-I` (insert) weit nach oben setzen.
