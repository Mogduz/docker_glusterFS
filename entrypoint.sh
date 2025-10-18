#!/bin/sh
# GlusterFS server entrypoint (POSIX sh) with MODE support: brick|host|solo

set -eu

# enforce deterministic output for parsing
export LANG=C
export LC_ALL=C

PATH=/usr/sbin:/usr/bin:/sbin:/bin
GLUSTERD_BIN=${GLUSTERD_BIN:-/usr/sbin/glusterd}
GLUSTER_BIN=${GLUSTER_BIN:-/usr/sbin/gluster}
GLUSTERD_VOL=${GLUSTERD_VOL:-/etc/glusterfs/glusterd.vol}

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
warn() { log "WARN: $*"; }
die() { log "ERROR: $*"; exit 1; }

# normalize boolean-ish env vars (1|y|yes|true|on)
    is_true() {
      case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
        1|y|yes|true|on) return 0 ;;
        *) return 1 ;;
      esac
    }

# ---------- Defaults (can be overridden by env) ----------
MODE=${MODE:-solo}                               # brick|host|solo
ADDRESS_FAMILY=${ADDRESS_FAMILY:-inet}           # inet|inet6
BIND_ADDR=${BIND_ADDR:-${PRIVATE_IP:-}}          # optional bind address
DATA_PORT_START=${DATA_PORT_START:-49152}
DATA_PORT_END=${DATA_PORT_END:-60999}
VOL_BOOTSTRAP=${VOL_BOOTSTRAP:-false}            # true|false (will be forced true in MODE=solo)
VOLNAME=${VOLNAME:-gv0}
VOLUMES=${VOLUMES:-$VOLNAME}                    # comma-separated list of volumes (defaults to VOLNAME)
QUOTA_LIMITS=${QUOTA_LIMITS:-}                   # comma-separated vol=size, e.g. gv0=100G,gv1=1T

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
            [ -n "$REPLICA" ] || REPLICA=2
            ;;
        host|brick)
            # leave REPLICA as provided by user (no implicit default)
            : ;
            ;;
        *)
            warn "Unknown MODE=$MODE; proceeding without changing REPLICA"
            : ;
            ;;
    esac
}

bootstrap_all_volumes() {
    is_true "$VOL_BOOTSTRAP" || { log "VOL_BOOTSTRAP=false -> skipping"; return 0; }
    if "$GLUSTER_BIN" --mode=script volume info "$VOLNAME" >/dev/null 2>&1; then
        log "Volume $VOLNAME already exists"
        return 0
    fi

    host="$(pick_hostname)"
    bricks="$(discover_bricks)"
    if [ -z "$bricks" ]; then
        if [ "$MODE" = "solo" ]; then
            : "${REPLICA:=2}"
            log "No bricks discovered; creating $REPLICA default bricks under /bricks"
            bricks=""
            i=1
            while [ "$i" -le "$REPLICA" ]; do
                d="/bricks/brick${i}"
                mkdir -p "$d"
                bricks="$bricks $d"
                i=$((i+1))
            done
            bricks="$(printf '%s\n' $bricks)"
        else
            warn "No bricks discovered; cannot bootstrap volume"
            return 0
        fi
    fi

    # Ensure brick count fits replica multiplier
    set -- $bricks
    count=$#
    if [ $((count % REPLICA)) -ne 0 ]; then
        warn "Brick count ($count) is not a multiple of replica ($REPLICA); volume create may fail"
    fi

    spec=""
    for b in "$@"; do
        [ -d "${b}/${VOLNAME}" ] || mkdir -p "${b}/${VOLNAME}"
        spec="$spec ${host}:${b}/${VOLNAME}"
    done

    log "Creating volume: $VOLNAME (replica=$REPLICA transport=$TRANSPORT)"
    if ! "$GLUSTER_BIN" volume create "$VOLNAME" replica "$REPLICA" transport "$TRANSPORT" $spec force; then
        die "Failed to create volume $VOLNAME"
    fi

    # Optional options
    if is_true "$NFS_DISABLE"; then
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

    if ! is_true "$REQUIRE_ALL_PEERS"; then
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

# Return quota size for a given volume from QUOTA_LIMITS (format: vol=size[,vol2=size2])
quota_size_for() {
    vol="$1"
    IFS=, ; set -- $QUOTA_LIMITS ; unset IFS
    for kv in "$@"; do
        [ -n "$kv" ] || continue
        case "$kv" in
            ${vol}=*|${vol}=\ *)
                printf '%s' "${kv#*=}" | tr -d ' '
                return 0
                ;;
        esac
    done
    return 1
}

apply_quota_for_volume() {
    vol="$1"
    [ -n "$QUOTA_LIMITS" ] || { log "No QUOTA_LIMITS specified; skipping quota for $vol"; return 0; }
    if ! size="$(quota_size_for "$vol")"; then
        log "No quota entry for volume $vol; skipping quota"
        return 0
    fi
    log "Enabling quota on $vol and setting limit $size for path /"
    "$GLUSTER_BIN" volume quota "$vol" enable >/dev/null 2>&1 || warn "quota enable failed (maybe already enabled)"
    if ! "$GLUSTER_BIN" volume quota "$vol" limit-usage / "$size"; then
        warn "Failed to set quota limit $size for $vol:/"
        return 1
    fi
    # Optional soft-limit percentage
    if [ -n "${QUOTA_SOFT_PCT:-}" ]; then
        "$GLUSTER_BIN" volume set "$vol" features.soft-limit "${QUOTA_SOFT_PCT}%" >/dev/null 2>&1 || warn "Failed to set soft-limit ${QUOTA_SOFT_PCT}% on $vol"
    fi
    log "Quota configured on $vol"
}

bootstrap_all_volumes() {
    # Iterate volumes in VOLUMES (comma-separated), preserving original VOLNAME default
    orig_vol="${VOLNAME:-}"
    IFS=, ; set -- $VOLUMES ; unset IFS
    for vol in "$@"; do
        [ -n "$vol" ] || continue
        VOLNAME="$vol"
        log "Bootstrapping volume: $VOLNAME"
        bootstrap_volume
        reconcile_volume_settings "$VOLNAME"
    done
    VOLNAME="$orig_vol"
}

# --- YAML-driven multi-volume support (subset YAML parser via awk) ---
# Expected schema:
# volumes:
#   - name: gv0
#     replica: 2
#     transport: tcp
#     auth_allow: 10.0.0.0/24
#     nfs_disable: true
#     options:
#       performance.client-io-threads: on
#       cluster.quorum-type: auto
#     quota:
#       limit: 200G
#       soft_limit_pct: 80
#
emit_yaml_specs() {
    file="$1"
    [ -s "$file" ] || return 1
    awk '
        function ltrim(s){ sub(/^\s+/, "", s); return s }
        function rtrim(s){ sub(/\s+$/, "", s); return s }
        function trim(s){ return rtrim(ltrim(s)) }
        BEGIN{ in_vols=0; in_vol=0; sect=""; sect_indent=-1; }
        /^[[:space:]]*#/ { next }    # skip comments
        /^[[:space:]]*$/ { next }    # skip empty
        /^volumes:[[:space:]]*$/ { in_vols=1; next }
        {
            line=$0
            indent=match(line,/[^ ]/) - 1
            gsub(/^[ ]+/, "", line)
            if (in_vols && substr(line,1,1)=="-") {
                # start of new volume item
                if (in_vol) {
                    print "__END_VOL__"
                }
                in_vol=1
                sect=""; sect_indent=-1
                print "__BEGIN_VOL__"
                rest=trim(substr(line,2))
                if (rest ~ /name:[[:space:]]*/) {
                    val=rest; sub(/^name:[[:space:]]*/,"",val)
                    gsub(/^["'''"]|["'''"]$/,"",val)
                    print "name=" val
                }
                next
            }
            if (!in_vol) next

            # key: value or key:
            split(line, kv, ":")
            key=trim(kv[1])
            val=""
            if (index(line,":")>0) { val=trim(substr(line, index(line,":")+1)) }

            if (val=="") {
                # section start
                sect=key
                sect_indent=indent
                next
            } else {
                # scalar or nested kv
                gsub(/^["'''"]|["'''"]$/,"",val)
                if (sect!="" && indent>sect_indent) {
                    print sect "." key "=" val
                } else {
                    print key "=" val
                }
            }
        }
        END{
            if (in_vol) print "__END_VOL__"
        }
    ' "$file"
}

apply_spec_line() {
    # Accept known keys, map to envs used by bootstrap logic
    k="$1"; v="$2"
    case "$k" in
        name) VOLNAME="$v" ;;
        replica) REPLICA="$v" ;;
        transport) TRANSPORT="$v" ;;
        auth_allow) AUTH_ALLOW="$v" ;;
        nfs_disable) NFS_DISABLE="$(printf "%s" "$v" | tr A-Z a-z | sed -e s/true/1/ -e s/false/0/)" ;;
        quota.limit) YAML_QUOTA_LIMIT="$v" ;;
        quota.soft_limit_pct) YAML_QUOTA_SOFT="$v" ;;
        options.*)
            opt="${k#options.}"
            if [ -z "${VOL_OPTS:-}" ]; then VOL_OPTS="${opt}=${v}"; else VOL_OPTS="${VOL_OPTS},${opt}=${v}"; fi
            ;;
        options_reset)
            YAML_RESET_OPTS="$v"
            ;;
        *)
            warn "Unknown key in YAML: $k (ignored)"
            ;;
    esac
}

bootstrap_from_yaml_or_env() {
    if [ -s "$VOLUMES_YAML" ]; then
        log "Using YAML spec at $VOLUMES_YAML"
        emit_yaml_specs "$VOLUMES_YAML" | while IFS= read -r line; do
            case "$line" in
                __BEGIN_VOL__)
                    # reset per-volume vars
                    VOLNAME=""
                    REPLICA="${REPLICA:-2}"
                    TRANSPORT="${TRANSPORT:-tcp}"
                    VOL_OPTS=""
                    AUTH_ALLOW="${AUTH_ALLOW:-}"
                    NFS_DISABLE="${NFS_DISABLE:-1}"
                    YAML_QUOTA_LIMIT=""
                    YAML_QUOTA_SOFT=""
                    ;;
                __END_VOL__)
                    [ -n "$VOLNAME" ] || { warn "YAML entry without name -> skipped"; continue; }
                    log "Bootstrapping (YAML) volume: $VOLNAME (replica=${REPLICA:-}, transport=${TRANSPORT:-})"
                    bootstrap_volume
                    if [ -n "$YAML_QUOTA_LIMIT" ]; then
                        QUOTA_LIMITS="${VOLNAME}=${YAML_QUOTA_LIMIT}"
                        QUOTA_SOFT_PCT="$YAML_QUOTA_SOFT"
                        reconcile_volume_settings "$VOLNAME"
                    fi
                    ;;
                *=*)
                    k="${line%%=*}"
                    v="${line#*=}"
                    apply_spec_line "$k" "$v"
                    ;;
                *)
                    ;;
            esac
        done
    else
        # Fallback: legacy env-driven multi-volume logic
        bootstrap_all_volumes
    fi
}

# Apply options/auth/quota to an existing or just-created volume according to current YAML vars
reconcile_volume_settings() {
    vol="$1"
    # Options (VOL_OPTS is comma-separated key=value list)
    if [ -n "${VOL_OPTS:-}" ]; then
        IFS=, ; set -- $VOL_OPTS ; unset IFS
        for kv in "$@"; do
            [ -n "$kv" ] || continue
            key="${kv%%=*}"; val="${kv#*=}"
            log "Setting option on $vol: ${key}=${val}"
            "$GLUSTER_BIN" volume set "$vol" "$key" "$val" >/dev/null 2>&1 || warn "Failed to set $key on $vol"
        done
    fi

    # Optional: reset options listed in YAML_RESET_OPTS (comma-separated keys)
    if [ -n "${YAML_RESET_OPTS:-}" ]; then
        IFS=, ; set -- $YAML_RESET_OPTS ; unset IFS
        for key in "$@"; do
            key="$(printf '%s' "$key" | tr -d ' ')"
            [ -n "$key" ] || continue
            log "Resetting option on $vol: ${key}"
            "$GLUSTER_BIN" volume reset "$vol" "$key" >/dev/null 2>&1 || warn "Failed to reset $key on $vol"
        done
    fi

    # auth.allow management
    if [ "${AUTH_ALLOW+set}" = "set" ]; then
        if [ -z "$AUTH_ALLOW" ]; then
            log "Resetting auth.allow on $vol (empty value in YAML)"
            "$GLUSTER_BIN" volume reset "$vol" auth.allow >/dev/null 2>&1 || warn "Failed to reset auth.allow on $vol"
        else
            log "Setting auth.allow on $vol to: $AUTH_ALLOW"
            "$GLUSTER_BIN" volume set "$vol" auth.allow "$AUTH_ALLOW" >/dev/null 2>&1 || warn "Failed to set auth.allow on $vol"
        fi
    fi

    # nfs.disable (expects on/off)
    if [ "${NFS_DISABLE+set}" = "set" ]; then
        state="$( [ "$NFS_DISABLE" = "1" ] && echo on || echo off )"
        log "Setting nfs.disable on $vol to: $state"
        "$GLUSTER_BIN" volume set "$vol" nfs.disable "$state" >/dev/null 2>&1 || warn "Failed to set nfs.disable on $vol"
    fi

    # Quota (idempotent)
    if [ -n "${YAML_QUOTA_LIMIT:-}" ]; then
        case "$(printf '%s' "$YAML_QUOTA_LIMIT" | tr A-Z a-z)" in
            off|disable|0)
                log "Disabling quota on $vol per YAML"
                "$GLUSTER_BIN" volume quota "$vol" disable >/dev/null 2>&1 || warn "quota disable failed on $vol"
                ;;
            *)
                log "Enabling quota on $vol and setting / to $YAML_QUOTA_LIMIT"
                "$GLUSTER_BIN" volume quota "$vol" enable >/dev/null 2>&1 || warn "quota enable failed on $vol (maybe already enabled)"
                "$GLUSTER_BIN" volume quota "$vol" limit-usage / "$YAML_QUOTA_LIMIT" >/dev/null 2>&1 || warn "Failed to set quota limit on $vol"
                if [ -n "${YAML_QUOTA_SOFT:-}" ]; then
                    "$GLUSTER_BIN" volume set "$vol" features.soft-limit "${YAML_QUOTA_SOFT}%" >/dev/null 2>&1 || warn "Failed to set soft-limit on $vol"
                fi
                ;;
        esac
    fi
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
    bootstrap_from_yaml_or_env
    # Wait on glusterd
    wait "$gpid"
}

main "$@"