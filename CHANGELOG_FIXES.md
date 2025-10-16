- Komplett-Repo überarbeitet: Dockerfile fix, Compose-Normalisierung, .env Defaults, Firewall-Skript (FORWARD), YAML-Validierung.


## 2025-10-16 22:13:44 Fixes
- entrypoint: honor DATA_PORT_END via MAX_PORT alias, ensuring Gluster uses the same port window as Compose publishes.
- docker-compose.override.yml: shrink default data port window to 49152–49251 to avoid slow startup from publishing thousands of ports.
- compose.solo-2bricks-replica.yml: drop deprecated `version` key to silence compose warning.


## 2025-10-16 22:34:44 Port-range hardening
- Default data-port window set to 49152–49251 across repo (Compose, Dockerfile, README, .env.example).
- Entrypoint ensures Gluster `max-port` honors DATA_PORT_END.
- Removed obsolete `version:` in compose files to avoid warnings.
