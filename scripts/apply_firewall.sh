#!/usr/bin/env bash
set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -f "${REPO_DIR}/.env" ]; then . "${REPO_DIR}/.env"; fi
PUBLIC_IF="${PUBLIC_IF:-}"
PRIVATE_CIDR="${PRIVATE_CIDR:-10.0.0.0/24}"
MGMT_PORT1="${MGMT_PORT1:-24007}"
MGMT_PORT2="${MGMT_PORT2:-24008}"
DATA_PORT_START="${DATA_PORT_START:-49152}"
DATA_PORT_END="${DATA_PORT_END:-49251}"
ts(){ date -u +"[%Y-%m-%dT%H:%M:%S+00:00]"; }
info(){ echo "$(ts) [INFO] $*"; }
ok(){   echo "$(ts) [OK]   $*"; }
err(){  echo "$(ts) [ERR]  $*" >&2; }
command -v ip >/dev/null || { err "ip not found"; exit 1; }
command -v iptables >/dev/null || { err "iptables not found"; exit 1; }
if [ -z "${PUBLIC_IF}" ]; then
  PUBLIC_IF="$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')"
  [ -n "${PUBLIC_IF}" ] || { err "Could not auto-detect PUBLIC_IF. Set PUBLIC_IF."; exit 1; }
  info "Auto-detected PUBLIC_IF=${PUBLIC_IF}"
else
  info "Using PUBLIC_IF=${PUBLIC_IF}"
fi
add_rule_v4(){ iptables -C "$@" 2>/dev/null || iptables -I "$@"; }
add_rule_v4 FORWARD -i "${PUBLIC_IF}" -p tcp -m multiport --dports "${MGMT_PORT1},${MGMT_PORT2}" -s "${PRIVATE_CIDR}" -j ACCEPT
add_rule_v4 FORWARD -i "${PUBLIC_IF}" -p tcp --dport "${DATA_PORT_START}:${DATA_PORT_END}" -s "${PRIVATE_CIDR}" -j ACCEPT
add_rule_v4 FORWARD -i "${PUBLIC_IF}" -p tcp -m multiport --dports "${MGMT_PORT1},${MGMT_PORT2}" -j DROP
add_rule_v4 FORWARD -i "${PUBLIC_IF}" -p tcp --dport "${DATA_PORT_START}:${DATA_PORT_END}" -j DROP
ok "Firewall-Regeln in FORWARD gesetzt (kein DOCKER-USER)."
iptables -nL FORWARD --line-numbers | sed -n '1,200p' || true
