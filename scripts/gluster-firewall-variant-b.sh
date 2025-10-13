\
#!/usr/bin/env bash
set -euo pipefail
CHAIN="${CHAIN:-DOCKER-USER}"
CIDR="${PRIVATE_CIDR:-10.0.0.0/24}"
PORTS_MGMT="24007,24008"
DATA_START=49152
DATA_END=49251
ipt(){ iptables "$@"; }
ensure_chain(){ ipt -S "$CHAIN" >/dev/null 2>&1 || ipt -N "$CHAIN" || true; }
have(){ ipt -C "$CHAIN" "$@" >/dev/null 2>&1; }
add_once(){ local pos="$1"; shift; have "$@" || ipt "$pos" "$CHAIN" "$@"; }
del_if(){ have "$@" && ipt -D "$CHAIN" "$@"; }
apply(){ ensure_chain;
  add_once -I -p tcp -m multiport --dports "$PORTS_MGMT" -s "$CIDR" -j ACCEPT
  add_once -I -p tcp --dport "${DATA_START}:${DATA_END}" -s "$CIDR" -j ACCEPT
  add_once -A -p tcp -m multiport --dports "$PORTS_MGMT" -j REJECT
  add_once -A -p tcp --dport "${DATA_START}:${DATA_END}" -j REJECT
  echo "[OK] Applied ${CHAIN} rules for ${CIDR}"
  if command -v netfilter-persistent >/dev/null 2>&1; then
    echo "[HINT] Persist: netfilter-persistent save"
  else
    echo "[HINT] Install: apt-get install -y netfilter-persistent && netfilter-persistent save"
  fi
}
remove(){
  del_if -p tcp -m multiport --dports "$PORTS_MGMT" -j REJECT
  del_if -p tcp --dport "${DATA_START}:${DATA_END}" -j REJECT
  del_if -p tcp -m multiport --dports "$PORTS_MGMT" -s "$CIDR" -j ACCEPT
  del_if -p tcp --dport "${DATA_START}:${DATA_END}" -s "$CIDR" -j ACCEPT
  echo "[OK] Removed ${CHAIN} rules for ${CIDR}"
}
status(){ ipt -S "$CHAIN" | grep -E '(24007|24008|49152|49251)' || true; }
case "${1:-}" in apply) apply;; remove) remove;; status) status;; *)
  echo "Usage: PRIVATE_CIDR=10.0.0.0/24 $0 {apply|remove|status}" >&2; exit 1;; esac
