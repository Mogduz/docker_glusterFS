#!/usr/bin/env bash
set -Eeo pipefail
# Solo mode startup extracted from entrypoint.sh
# This script expects the same environment variables that entrypoint.sh provides.

# shellcheck disable=SC2154
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
