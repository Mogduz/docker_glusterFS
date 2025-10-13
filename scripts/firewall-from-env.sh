\
#!/usr/bin/env bash
set -euo pipefail

# Manual iptables firewall for Gluster Variant B
# - Reads .env (PRIVATE_IP, PRIVATE_CIDR, optional PUBLIC_IF, CONTAINER_NAME, MGMT_PORTS, DATA_PORT_START/END)
# - Applies INPUT rules on public NIC and FORWARD rules to docker bridge used by the container
#
# Usage:
#   ./firewall-from-env.sh apply
#   ./firewall-from-env.sh remove
#   ./firewall-from-env.sh status
#   ./firewall-from-env.sh detect

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-${ROOT_DIR}/.env}"

require_root() { if [[ $EUID -ne 0 ]]; then echo "[ERR] run as root"; exit 1; fi; }

# Load env (key=value lines)
load_env() {
  if [[ -f "${ENV_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
  fi
  : "${PRIVATE_IP:?set in .env}"
  : "${PRIVATE_CIDR:?set in .env}"
  : "${PUBLIC_IF:=}"
  : "${CONTAINER_NAME:=gluster-solo}"
  : "${MGMT_PORTS:=24007,24008}"
  : "${DATA_PORT_START:=49152}"
  : "${DATA_PORT_END:=49251}"
}

# Helpers
ipt() { iptables "$@"; }
rule_exists() { ipt -C "$1" "${@:2}" >/dev/null 2>&1; } # chain, rest args
add_once() { local chain="$1"; shift; rule_exists "$chain" "$@" || ipt -I "$chain" "$@"; } # insert at top
append_once() { local chain="$1"; shift; rule_exists "$chain" "$@" || ipt -A "$chain" "$@"; }
del_if() { local chain="$1"; shift; rule_exists "$chain" "$@" && ipt -D "$chain" "$@"; }

detect_public_if() {
  if [[ -n "${PUBLIC_IF}" ]]; then echo "${PUBLIC_IF}"; return 0; fi
  # try default route
  local dev
  dev=$(ip route get 1.1.1.1 2>/dev/null | awk '/dev/ {for(i=1;i<=NF;i++){if($i=="dev"){print $(i+1); exit}}}')
  if [[ -n "$dev" ]]; then echo "$dev"; return 0; fi
  # fallback
  dev=$(ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++){if($i=="dev"){print $(i+1); exit}}}')
  echo "$dev"
}

detect_bridge_if() {
  # Find the docker network bridge used by the container
  local net_id br_name
  net_id=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.NetworkID}}{{end}}' "${CONTAINER_NAME}" 2>/dev/null || true)
  if [[ -z "$net_id" ]]; then
    echo ""
    return 0
  fi
  # Ask docker for explicit bridge name
  br_name=$(docker network inspect "$net_id" -f '{{index .Options "com.docker.network.bridge.name"}}' 2>/dev/null || true)
  if [[ -n "$br_name" ]]; then
    echo "$br_name"; return 0
  fi
  # Fallback: standard br-<12 chars of id>
  echo "br-${net_id:0:12}"
}

print_detect() {
  echo "PRIVATE_IP=${PRIVATE_IP}"
  echo "PRIVATE_CIDR=${PRIVATE_CIDR}"
  echo "PUBLIC_IF=$(detect_public_if)"
  echo "BRIDGE_IF=$(detect_bridge_if)"
  echo "CONTAINER_NAME=${CONTAINER_NAME}"
  echo "MGMT_PORTS=${MGMT_PORTS}"
  echo "DATA_PORT_RANGE=${DATA_PORT_START}-${DATA_PORT_END}"
}

apply_rules() {
  require_root
  load_env
  local pub_if bridge_if
  pub_if=$(detect_public_if)
  bridge_if=$(detect_bridge_if)

  if [[ -z "${bridge_if}" ]]; then
    echo "[ERR] could not determine docker bridge for container ${CONTAINER_NAME}. Is it running?"; exit 1
  fi

  echo "[INFO] Using PUBLIC_IF=${pub_if}  BRIDGE_IF=${bridge_if}  CIDR=${PRIVATE_CIDR}"

  # 1) Public INPUT: reject Gluster ports on public interface (safety if someone binds to public IP by mistake)
  append_once INPUT -i "${pub_if}" -p tcp -m multiport --dports "${MGMT_PORTS}" -j REJECT
  append_once INPUT -i "${pub_if}" -p tcp --dport "${DATA_PORT_START}:${DATA_PORT_END}" -j REJECT

  # 2) FORWARD: allow only PRIVATE_CIDR -> bridge for Gluster ports; then reject the rest
  add_once FORWARD -p tcp -m multiport --dports "${MGMT_PORTS}" -s "${PRIVATE_CIDR}" -o "${bridge_if}" -j ACCEPT
  add_once FORWARD -p tcp --dport "${DATA_PORT_START}:${DATA_PORT_END}" -s "${PRIVATE_CIDR}" -o "${bridge_if}" -j ACCEPT
  append_once FORWARD -p tcp -m multiport --dports "${MGMT_PORTS}" -o "${bridge_if}" -j REJECT
  append_once FORWARD -p tcp --dport "${DATA_PORT_START}:${DATA_PORT_END}" -o "${bridge_if}" -j REJECT

  echo "[OK] Rules applied."
  echo "[HINT] Persist (Debian/Ubuntu): apt-get install -y netfilter-persistent && netfilter-persistent save"
}

remove_rules() {
  require_root
  load_env
  local pub_if bridge_if
  pub_if=$(detect_public_if)
  bridge_if=$(detect_bridge_if)

  # Remove in reverse order of application
  del_if FORWARD -p tcp --dport "${DATA_PORT_START}:${DATA_PORT_END}" -o "${bridge_if}" -j REJECT
  del_if FORWARD -p tcp -m multiport --dports "${MGMT_PORTS}" -o "${bridge_if}" -j REJECT
  del_if FORWARD -p tcp --dport "${DATA_PORT_START}:${DATA_PORT_END}" -s "${PRIVATE_CIDR}" -o "${bridge_if}" -j ACCEPT
  del_if FORWARD -p tcp -m multiport --dports "${MGMT_PORTS}" -s "${PRIVATE_CIDR}" -o "${bridge_if}" -j ACCEPT

  del_if INPUT -i "${pub_if}" -p tcp --dport "${DATA_PORT_START}:${DATA_PORT_END}" -j REJECT
  del_if INPUT -i "${pub_if}" -p tcp -m multiport --dports "${MGMT_PORTS}" -j REJECT

  echo "[OK] Rules removed."
}

status_rules() {
  load_env
  local pub_if bridge_if
  pub_if=$(detect_public_if)
  bridge_if=$(detect_bridge_if)
  echo "== INPUT (public ${pub_if}) =="
  iptables -S INPUT | grep -E "(${pub_if}).*(24007|24008|4915[2-9][0-9]|4925[0-1])" || true
  echo "== FORWARD (to ${bridge_if}) =="
  iptables -S FORWARD | grep -E "(24007|24008|49152|49251)" || true
  echo "== NAT (DNAT for published ports, for info) =="
  iptables -t nat -S PREROUTING | grep -E "(24007|24008|49152|49251)" || true
}

case "${1:-}" in
  apply)  apply_rules ;;
  remove) remove_rules ;;
  status) status_rules ;;
  detect) load_env; print_detect ;;
  *)
    echo "Usage: $0 {apply|remove|status|detect} [ENV_FILE=/path/to/.env]" >&2
    exit 1 ;;
esac
