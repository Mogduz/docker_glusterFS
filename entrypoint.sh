#!/bin/sh
# GlusterFS server entrypoint (POSIX sh) with MODE support: brick|host|solo

set -eu

PATH=/usr/sbin:/usr/bin:/sbin:/bin
GLUSTERD_BIN=${GLUSTERD_BIN:-/usr/sbin/glusterd}
GLUSTER_BIN=${GLUSTER_BIN:-/usr/sbin/gluster}
GLUSTERD_VOL=${GLUSTERD_VOL:-/etc/glusterfs/glusterd.vol}

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
warn() { log "WARN: $*"; }
die() { log "ERROR: $*"; exit 1; }

# ---------- Defaults (can be overridden by env) ----------
MODE=${MODE:-solo}                               # brick|host|solo
ADDRESS_FAMILY=${ADDRESS_FAMILY:-inet}           # inet|inet6
BIND_ADDR=${BIND_ADDR:-${PRIVATE_IP:-}}          # optional bind address
DATA_PORT_START=${DATA_PORT_START:-49152}
DATA_PORT_END=${DATA_PORT_END:-60999}
VOL_BOOTSTRAP=${VOL_BOOTSTRAP:-false}            # true|false (will be forced true in MODE=solo)
VOLNAME=${VOLNAME:-gv0}
REPLICA=${REPLICA:-}                             # default depends on MODE
TRANSPORT=${TRANSPORT:-tcp}
NFS_DISABLE=${NFS_DISABLE:-true}
AUTH_ALLOW=${AUTH_ALLOW:-}                        # e.g. 10.0.0.0/8,192.168.0.0/16
VOL_OPTS=${VOL_OPTS:-}                            # CSV: key=value,key=value

BRICK_DIRS=${BRICK_DIRS:-}                        # CSV of absolute paths; if empty -> /bricks/*

# Cluster join/init knobs (used in MODE=host)
PEERS=${PEERS:-}                                  # CSV of hostnames/IPs to peer probe
REQUIRE_ALL_PEERS=${REQUIRE_ALL_PEERS:-false}     # true|false

GLUSTERD_READY_TIMEOUT=${GLUSTERD_READY_TIMEOUT:-120}
PEER_WAIT_TIMEOUT=${PEER_WAIT_TIMEOUT:-180}

# ---------- Helpers ----------
add_option_in_mgmt_block() {
    # Usage: add_option_in_mgmt_block "key" "value"
    key="$1"; val="$2"
    [ -f "$GLUSTERD_VOL" ] || die "glusterd.vol not found at $GLUSTERD_VOL"
    if grep -Eq "^[[:space:]]*option[[:space:]]+$key[[:space:]]+" "$GLUSTERD_VOL"; then
        # replace existing value
        sed -i "s|^\([[:space:]]*option[[:space:]]\+$key[[:space:]]\+\).*|\1$val|g" "$GLUSTERD_VOL"
        return 0
    fi
    # insert before 'end-volume' of 'volume management' block
    awk -v k="$key" -v v="$val" '
        BEGIN{inblk=0}
        /^volume[[:space:]]+management/ {inblk=1}
        inblk && /^end-volume/ {print "    option " k " " v; inblk=0}
        {print}
    ' "$GLUSTERD_VOL" > "$GLUSTERD_VOL.tmp" && mv "$GLUSTERD_VOL.tmp" "$GLUSTERD_VOL"
}

ensure_glusterd_config() {
    log "Configuring glusterd.vol options"
    # Address family
    add_option_in_mgmt_block "transport.address-family" "$ADDRESS_FAMILY"
    # Optional bind address
    if [ -n "$BIND_ADDR" ]; then
        add_option_in_mgmt_block "transport.socket.bind-address" "$BIND_ADDR"
    fi
    # Data port window
    add_option_in_mgmt_block "base-port" "$DATA_PORT_START"
    add_option_in_mgmt_block "max-port" "$DATA_PORT_END"
    # Allow insecure RPC if desired (kept off by default)
    if [ "${RPC_ALLOW_INSECURE:-}" = "on" ]; then
        add_option_in_mgmt_block "rpc-auth-allow-insecure" "on"
    fi
}

wait_for_glusterd() {
    i=0
    until "$GLUSTER_BIN" --mode=script volume list >/dev/null 2>&1; do
        i=$((i+1))
        if [ "$i" -gt "$GLUSTERD_READY_TIMEOUT" ]; then
            die "glusterd did not become ready in time"
        fi
        sleep 1
    done
    log "glusterd is ready"
}

pick_hostname() {
    hn="$(hostname -f 2>/dev/null || true)"
    [ -n "$hn" ] || hn="$(hostname 2>/dev/null || echo gluster)"
    printf '%s' "$hn"
}

discover_bricks() {
    if [ -n "$BRICK_DIRS" ]; then
        IFS=, ; set -- $BRICK_DIRS ; unset IFS
        for d in "$@"; do
            [ -d "$d" ] || mkdir -p "$d"
            printf '%s\n' "$d"
        done
        return 0
    fi
    if [ -d /bricks ]; then
        for d in /bricks/*; do
            [ -d "$d" ] || continue
            printf '%s\n' "$d"
        done
    fi
}

ensure_replica_defaults_for_mode() {
    case "$MODE" in
        solo)
            # default replica 2 for solo
            [ -n "$REPLICA" ] || REPLICA=2
            ;;
        host|brick)
            # do not force replica; leave as-is (may be set by user if VOL_BOOTSTRAP=true on host)
            [ -n "$REPLICA" ] || REPLICA=2
            ;;
        *)
            warn "Unknown MODE=$MODE; proceeding with defaults"
            [ -n "$REPLICA" ] || REPLICA=2
            ;;
    esac
}

bootstrap_volume() {
    [ "$VOL_BOOTSTRAP" = "true" ] || { log "VOL_BOOTSTRAP=false -> skipping"; return 0; }
    if "$GLUSTER_BIN" --mode=script volume info "$VOLNAME" >/dev/null 2>&1; then
        log "Volume $VOLNAME already exists"
        return 0
    fi

    host="$(pick_hostname)"
    bricks="$(discover_bricks)"
    if [ -z "$bricks" ]; then
        warn "No bricks discovered; cannot bootstrap volume"
        return 0
    fi

    # Ensure brick count fits replica multiplier
    set -- $bricks
    count=$#
    if [ $((count % REPLICA)) -ne 0 ]; then
        warn "Brick count ($count) is not a multiple of replica ($REPLICA); volume create may fail"
    fi

    spec=""
    for b in "$@"; do
        spec="$spec ${host}:${b}"
    done

    log "Creating volume: $VOLNAME (replica=$REPLICA transport=$TRANSPORT)"
    if ! "$GLUSTER_BIN" volume create "$VOLNAME" replica "$REPLICA" transport "$TRANSPORT" $spec force; then
        die "Failed to create volume $VOLNAME"
    fi

    # Optional options
    if [ "$NFS_DISABLE" = "true" ]; then
        "$GLUSTER_BIN" volume set "$VOLNAME" nfs.disable on >/dev/null 2>&1 || true
    fi
    if [ -n "$AUTH_ALLOW" ]; then
        "$GLUSTER_BIN" volume set "$VOLNAME" auth.allow "$AUTH_ALLOW" >/dev/null 2>&1 || true
    fi
    if [ -n "$VOL_OPTS" ]; then
        IFS=, ; set -- $VOL_OPTS ; unset IFS
        for kv in "$@"; do
            key="${kv%%=*}"; val="${kv#*=}"
            [ -n "$key" ] || continue
            "$GLUSTER_BIN" volume set "$VOLNAME" "$key" "$val" >/dev/null 2>&1 || warn "Failed to set $key"
        done
    fi

    "$GLUSTER_BIN" volume start "$VOLNAME" force || die "Failed to start volume $VOLNAME"
    log "Volume $VOLNAME created and started"
}

peer_probe_and_wait() {
    [ -n "$PEERS" ] || { log "No PEERS specified; skipping peer probe"; return 0; }
    IFS=, ; set -- $PEERS ; unset IFS
    for p in "$@"; do
        log "Peer probing $p"
        "$GLUSTER_BIN" peer probe "$p" >/dev/null 2>&1 || warn "peer probe $p failed (may already be in cluster)"
    done

    if [ "$REQUIRE_ALL_PEERS" != "true" ]; then
        log "Not waiting for all peers (REQUIRE_ALL_PEERS=false)"
        return 0
    fi

    log "Waiting for peers to be Connected (timeout ${PEER_WAIT_TIMEOUT}s)"
    deadline=$(( $(date +%s) + PEER_WAIT_TIMEOUT ))
    while : ; do
        out="$("$GLUSTER_BIN" peer status 2>/dev/null || true)"
        ok=1
        for p in "$@"; do
            printf '%s' "$out" | grep -q "Hostname: $p" && printf '%s' "$out" | sed -n '/Hostname: '"$p"'/,/^$/p' | grep -q 'State: Peer in Cluster (Connected)' || ok=0
        done
        if [ "$ok" -eq 1 ]; then
            log "All peers are Connected"
            break
        fi
        [ "$(date +%s)" -lt "$deadline" ] || { warn "Timed out waiting for peers"; break; }
        sleep 2
    done
}

forward_signals() {
    pid="$1"
    term() {
        log "Forwarding SIGTERM to glusterd (pid $pid)"
        kill -TERM "$pid" 2>/dev/null || true
        wait "$pid" || true
        exit 0
    }
    trap term TERM INT
}

main() {
    log "MODE=$MODE"
    ensure_glusterd_config

    # Start glusterd in foreground
    "$GLUSTERD_BIN" -N &
    gpid=$!
    forward_signals "$gpid"

    wait_for_glusterd

    case "$MODE" in
        brick)
            log "MODE=brick -> no volume bootstrap, no peer actions"
            ;;
        host)
            log "MODE=host -> optional peer probe and optional volume bootstrap"
            peer_probe_and_wait
            ;;
        solo)
            log "MODE=solo -> will ensure sensible defaults and bootstrap volume locally"
            VOL_BOOTSTRAP=true
            ;;
        *)
            warn "Unknown MODE=$MODE -> treating as 'solo-like'"
            VOL_BOOTSTRAP=true
            ;;
    esac

    ensure_replica_defaults_for_mode
    bootstrap_volume

    # Wait on glusterd
    wait "$gpid"
}

main "$@"
