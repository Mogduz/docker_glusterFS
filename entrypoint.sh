\
    #!/usr/bin/env bash
    # GlusterFS server entrypoint (verbose/communicative)
    set -Eeuo pipefail

    # -------- Logging --------
    COLOR="${COLOR:-1}"          # 1=colorized if TTY, 0=plain
    TRACE="${TRACE:-0}"          # 1=enable shell xtrace; 2=very noisy
    CTX="startup"

    is_tty() { [[ -t 1 ]] && [[ "${COLOR}" == "1" ]]; }

    if is_tty; then
      C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
      C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YLW=$'\033[33m'; C_BLU=$'\033[34m'
    else
      C_RESET=; C_DIM=; C_BOLD=; C_RED=; C_GRN=; C_YLW=; C_BLU=
    fi

    ts() { date -Iseconds; }
    _log() { # level, message...
      local lvl="$1"; shift
      local tag="[$(ts)] [$lvl] ($CTX)"
      case "$lvl" in
        DEBUG) printf "%s %s%s%s\n" "$tag" "$C_DIM" "$*" "$C_RESET" ;;
        INFO)  printf "%s %s\n"       "$tag" "$*" ;;
        WARN)  printf "%s %s%s%s\n" "$tag" "${C_YLW}" "$*" "$C_RESET" ;;
        ERROR) printf "%s %s%s%s\n" "$tag" "${C_RED}" "$*" "$C_RESET" ;;
        STEP)  printf "%s %s%s%s\n" "$tag" "${C_BLU}${C_BOLD}" "$*" "$C_RESET" ;;
        OK)    printf "%s %s%s%s\n" "$tag" "${C_GRN}" "$*" "$C_RESET" ;;
        *)     printf "%s %s\n" "$tag" "$*";;
      esac
    }
    debug(){ _log DEBUG "$@"; }
    info(){  _log INFO  "$@"; }
    warn(){  _log WARN  "$@"; }
    error(){ _log ERROR "$@"; }
    step(){  _log STEP  "===== $* ====="; }
    ok(){    _log OK    "$@"; }

    if (( TRACE > 0 )); then
      exec 3>&1
      export BASH_XTRACEFD=3
      export PS4='+ [${EPOCHREALTIME}] ${BASH_SOURCE##*/}:${LINENO} ${FUNCNAME[0]:-main}() '
      set -x
      debug "Shell TRACE enabled (level=$TRACE)"
    fi

    on_error() {
      local ec=$?
      local line="${BASH_LINENO[0]:-?}"
      local src="${BASH_SOURCE[1]:-entrypoint}"
      local cmd="${BASH_COMMAND:-?}"
      error "Fehler (rc=$ec) in ${src}:${line} → ${cmd}"
      if compgen -G "/var/log/glusterfs/*.log" > /dev/null; then
        echo "--- gluster logs (tail -n 100) ---"
        tail -n 100 /var/log/glusterfs/*.log | sed 's/^/gluster| /'
        echo "----------------------------------"
      fi
      exit "$ec"
    }
    trap on_error ERR

    # -------- Config --------
    MODE="${MODE:-brick}"                        # brick | init
    VOLNAME="${VOLNAME:-gv0}"
    VOLFALLBACK="${VOLFALLBACK:-gv0}"            # nur relevant, wenn VOLNAME=auto und create gewünscht (derzeit nicht auto)
    VTYPE="${VTYPE:-replica}"                    # replica | disperse
    REPLICA="${REPLICA:-3}"
    DISPERSE="${DISPERSE:-6}"                    # VTYPE=disperse
    REDUNDANCY="${REDUNDANCY:-2}"                # VTYPE=disperse
    BRICK_PATH="${BRICK_PATH:-/bricks/brick1}"
    PEERS="${PEERS:-}"
    AUTO_ADD_BRICK="${AUTO_ADD_BRICK:-0}"        # nur sicher bei REPLICA=1
    ADD_BRICK_SET="${ADD_BRICK_SET:-}"           # kompletter Satz (Vielfaches v. REPLICA)
    ALLOW_FORCE_CREATE="${ALLOW_FORCE_CREATE:-0}"
    ALLOW_EMPTY_STATE="${ALLOW_EMPTY_STATE:-0}"
    REQUIRE_ALL_PEERS="${REQUIRE_ALL_PEERS:-1}"
    REQUIRE_MOUNTED_BRICK="${REQUIRE_MOUNTED_BRICK:-0}"
    ADDRESS_FAMILY="${ADDRESS_FAMILY:-}"
    PORT_RANGE="${PORT_RANGE:-49152-49251}"
    LOG_LEVEL="${LOG_LEVEL:-WARNING}"
    ENABLE_SSL="${ENABLE_SSL:-0}"
    VOLUME_PROFILE="${VOLUME_PROFILE:-}"         # optional: vm
    PEER_WAIT_SECS="${PEER_WAIT_SECS:-120}"      # -1 = unendlich, 0 = nicht warten, >0 Sekunden
    PEER_WAIT_INTERVAL="${PEER_WAIT_INTERVAL:-1}"

    step "Startparameter"
    cat <<ENV | sed 's/^/  /'
    MODE=$MODE
    VOLNAME=$VOLNAME
    VTYPE=$VTYPE
    REPLICA=$REPLICA
    DISPERSE=$DISPERSE
    REDUNDANCY=$REDUNDANCY
    BRICK_PATH=$BRICK_PATH
    PEERS=$PEERS
    REQUIRE_ALL_PEERS=$REQUIRE_ALL_PEERS
    ADDRESS_FAMILY=${ADDRESS_FAMILY:-unset}
    PORT_RANGE=$PORT_RANGE
    LOG_LEVEL=$LOG_LEVEL
    TRACE=$TRACE
    PEER_WAIT_SECS=$PEER_WAIT_SECS
    PEER_WAIT_INTERVAL=$PEER_WAIT_INTERVAL
    ENV

    # -------- Helpers --------
    to_arr(){ IFS=',' read -ra _ARR <<< "$1"; }
    run(){ info "RUN: $*"; "$@"; }
    require_cmd(){ command -v "$1" >/dev/null || { error "Binary fehlt: $1"; return 127; }; }

    start_glusterd(){
      CTX="glusterd"
      step "glusterd starten"
      require_cmd glusterd
      mkdir -p "$BRICK_PATH"
      if [[ "$REQUIRE_MOUNTED_BRICK" -eq 1 ]] && ! mountpoint -q "$BRICK_PATH"; then
        error "Brick-Pfad ist kein Mountpoint: $BRICK_PATH"; return 3
      fi
      touch "$BRICK_PATH/.glusterfs_brick" 2>/dev/null || { error "Brick-Pfad nicht beschreibbar: $BRICK_PATH"; return 4; }
      run glusterd -N &
      GLUSTERD_PID=$!
      trap 'CTX="shutdown"; info "Signal empfangen → glusterd beenden"; kill -TERM ${GLUSTERD_PID}; wait ${GLUSTERD_PID}' TERM INT
      info "Warte auf glusterd… (PID=${GLUSTERD_PID})"
      for i in {1..30}; do
        if pgrep -x glusterd >/dev/null; then ok "glusterd läuft"; break; fi
        sleep 1
      done
      pgrep -x glusterd >/dev/null || { error "glusterd startete nicht"; return 1; }
    }

    check_state_dir(){
      CTX="state"
      step "State-Verzeichnis prüfen"
      local cnt
      cnt=$(find /var/lib/glusterd -mindepth 1 -maxdepth 1 2>/dev/null | wc -l || true)
      if [[ "$cnt" -lt 2 && "$ALLOW_EMPTY_STATE" -ne 1 ]]; then
        warn "/var/lib/glusterd wirkt leer – ist der Volume-State gemountet? (ALLOW_EMPTY_STATE=1 zum Ignorieren)"
      else
        ok "State-Verzeichnis ok (Einträge: $cnt)"
      fi
    }

    probe_peers(){
      CTX="peers"
      [[ -z "$PEERS" ]] && { info "Keine PEERS definiert – Peer-Probing übersprungen"; return 0; }
      step "Peers proben"
      local self; self="$(hostname -s)"
      to_arr "$PEERS"
      for p in "${_ARR[@]}"; do
        [[ "$p" == "$self" ]] && continue
        run gluster peer probe "$p" || true
      done
    }

    peers_connected(){
      gluster peer status 2>/dev/null | grep -c 'Peer in Cluster (Connected)' || true
    }

    require_peer_quorum(){
      CTX="quorum"
      [[ -z "$PEERS" ]] && { info "Kein Peer-Quorum erforderlich (PEERS leer)"; return 0; }
      step "Auf Peer-Quorum warten"
      to_arr "$PEERS"
      local need
      if [[ "$REQUIRE_ALL_PEERS" -eq 1 ]]; then
        need=$((${#_ARR[@]} - 1)) # alle außer self
      else
        need=$(( REPLICA - 1 ))
      fi
      local interval=${PEER_WAIT_INTERVAL:-1}
      local target=${PEER_WAIT_SECS:-120}
      local waited=0
      info "Warte-Strategie: PEER_WAIT_SECS=$target, INTERVAL=$interval, benötigt=$need"
      if [[ "$target" == "-1" ]]; then
        while true; do
          local okc; okc=$(peers_connected)
          info "Verbunden: $okc / benötigt: $need (∞ wait)"
          if [[ "$okc" -ge "$need" ]]; then ok "Quorum erreicht"; return 0; fi
          sleep "$interval"
        done
      elif [[ "$target" -eq 0 ]]; then
        local okc; okc=$(peers_connected)
        info "Verbunden: $okc / benötigt: $need (no-wait)"
        if [[ "$okc" -ge "$need" ]]; then ok "Quorum erreicht (no-wait)"; return 0; fi
        warn "Peer-Quorum nicht erreicht (no-wait)."
        [[ "$MODE" == "init" ]] && { error "Abbruch im INIT-Modus ohne Quorum"; return 2; }
        return 0
      else
        while (( waited < target )); do
          local okc; okc=$(peers_connected)
          info "Verbunden: $okc / benötigt: $need (t+${waited}s)"
          if [[ "$okc" -ge "$need" ]]; then ok "Quorum erreicht"; return 0; fi
          sleep "$interval"
          waited=$((waited + interval))
        done
        warn "Peer-Quorum innerhalb ${target}s nicht erreicht."
        [[ "$MODE" == "init" ]] && { error "Abbruch im INIT-Modus nach Timeout"; return 2; }
        return 0
      fi
    }

    reconcile_peers_warn(){
      CTX="peer-drift"
      [[ -z "$PEERS" ]] && return 0
      step "Peer-Drift prüfen"
      to_arr "$PEERS"; declare -A want; for p in "${_ARR[@]}"; do want[$p]=1; done
      local pool; pool=$(gluster pool list 2>/dev/null | awk 'NR>1 {print $3}' || true)
      local seenCount=0; for seen in $pool; do seenCount=$((seenCount+1)); [[ -n "${want[$seen]:-}" ]] || warn "Unbekannter Peer im Pool: $seen"; done
      for p in "${_ARR[@]}"; do echo "$pool" | grep -qw "$p" || warn "Erwarteter Peer fehlt im Pool: $p"; done
      info "Pool-Einträge: $seenCount"
    }

    volume_exists(){ [[ -n "$VOLNAME" ]] && gluster volume info "$VOLNAME" >/dev/null 2>&1; }
    volume_started(){ gluster volume info "$VOLNAME" 2>/dev/null | awk '/Status:/ {print $2}' | grep -q '^Started$'; }

    ensure_volume_started(){
      CTX="volume-start"
      step "Volume-Start sicherstellen (${VOLNAME:-<leer>})"
      if [[ -z "$VOLNAME" ]]; then info "Kein VOLNAME gesetzt → übersprungen"; return 0; fi
      if volume_started; then ok "Volume bereits gestartet"; return 0; fi
      run gluster volume start "$VOLNAME"
      ok "Volume gestartet"
    }

    local_brick_present(){
      local self; self="$(hostname -s)"
      gluster volume info "$VOLNAME" 2>/dev/null | grep -qE "Brick[0-9]+: $self:$BRICK_PATH"
    }

    ensure_local_brick(){
      CTX="brick-verify"
      step "Lokalen Brick prüfen"
      if [[ -z "$VOLNAME" ]]; then info "Kein VOLNAME gesetzt → übersprungen"; return 0; fi
      if local_brick_present; then ok "Lokaler Brick ist Teil von $VOLNAME"; return 0; fi
      if [[ "$AUTO_ADD_BRICK" -eq 1 && "$REPLICA" -eq 1 ]]; then
        info "Lokaler Brick fehlt – füge hinzu (REPLICA=1)"
        run gluster volume add-brick "$VOLNAME" "$(hostname -s):$BRICK_PATH"
        warn "Rebalance/Heal empfohlen"
      elif [[ -n "$ADD_BRICK_SET" ]]; then
        to_arr "$ADD_BRICK_SET"; local n=${#_ARR[@]}
        if (( n % REPLICA == 0 )); then
          info "Füge kompletten Brick-Satz hinzu (${n} Hosts, replica $REPLICA)…"
          local bricks=(); for h in "${_ARR[@]}"; do bricks+=("${h}:$BRICK_PATH"); done
          run gluster volume add-brick "$VOLNAME" replica "$REPLICA" "${bricks[@]}"
          warn "Rebalance/Heal empfohlen"
        else
          warn "ADD_BRICK_SET-Anzahl ($n) ist kein Vielfaches von REPLICA ($REPLICA) – übersprungen"
        fi
      else
        warn "Lokaler Brick ist NICHT Teil des Volumes (keine Automatik ausgeführt)"
      fi
    }

    apply_volume_basics(){
      CTX="volume-tune"
      step "Volume-Basics anwenden"
      if [[ -z "$VOLNAME" ]]; then info "Kein VOLNAME gesetzt → übersprungen"; return 0; fi
      run gluster volume set "$VOLNAME" cluster.quorum-type auto || true
      run gluster volume set "$VOLNAME" network.ping-timeout 5 || true
      run gluster volume set "$VOLNAME" performance.client-io-threads on || true
      run gluster volume set "$VOLNAME" diagnostics.client-log-level "$LOG_LEVEL" || true
      run gluster volume set "$VOLNAME" diagnostics.brick-log-level "$LOG_LEVEL" || true
      [[ -n "$PORT_RANGE" ]]      && run gluster volume set "$VOLNAME" network.port-range "$PORT_RANGE" || true
      [[ -n "$ADDRESS_FAMILY" ]]  && run gluster volume set "$VOLNAME" transport.address-family "$ADDRESS_FAMILY" || true
      if [[ "$ENABLE_SSL" -eq 1 ]]; then
        warn "SSL aktiviert – stelle Zertifikate unter /etc/ssl/glusterfs bereit"
        run gluster volume set "$VOLNAME" auth.ssl on || true
      fi
      ok "Volume-Basics angewandt"
    }

    maybe_profile_workload(){
      CTX="workload-profile"
      case "$VOLUME_PROFILE" in
        vm)
          step "Profil: vm (Sharding)"
          run gluster volume set "$VOLNAME" features.shard on || true
          run gluster volume set "$VOLNAME" features.shard-block-size 64MB || true
          ;;
        "" ) info "Kein Workload-Profil gesetzt";;
        *  ) info "Unbekanntes Profil: $VOLUME_PROFILE (ignoriert)";;
      esac
    }

    # Autodetect existing volumes if VOLNAME=auto
    autodetect_volume(){
      CTX="vol-autodetect"
      if [[ "${VOLNAME}" != "auto" ]]; then
        debug "VOLNAME='${VOLNAME}' → keine Autodetektion nötig"
        return 0
      fi
      step "Volume-Autodetektion"
      local vols
      vols=$(gluster volume list 2>/dev/null | awk 'NF' || true)
      if [[ -z "$vols" ]]; then
        info "Keine Volumes sichtbar – bleibe im reinen Brick-Modus"
        VOLNAME=""
        return 0
      fi
      local count; count=$(echo "$vols" | wc -l | awk '{print $1}')
      local self; self="$(hostname -s)"
      if (( count == 1 )); then
        VOLNAME="$(echo "$vols" | head -n1)"
        ok "Ein vorhandenes Volume gefunden: ${VOLNAME}"
        return 0
      fi
      for v in $vols; do
        if gluster volume info "$v" 2>/dev/null | grep -qE "Brick[0-9]+: ${self}:${BRICK_PATH}"; then
          VOLNAME="$v"
          ok "Passendes Volume gefunden (enthält ${self}:${BRICK_PATH}): ${VOLNAME}"
          return 0
        fi
      done
      warn "Mehrere Volumes gefunden, aber keins enthält ${self}:${BRICK_PATH}. Keine Auswahl getroffen."
      VOLNAME=""
      return 0
    }

    create_volume_safely(){
      CTX="volume-create"
      step "Volume ggf. erstellen (${VOLNAME:-<leer>})"
      to_arr "$PEERS"; local bricks=(); for p in "${_ARR[@]}"; do bricks+=("${p}:${BRICK_PATH}"); done
      local maybe_force=(); [[ "$ALLOW_FORCE_CREATE" -eq 1 ]] && maybe_force=("force")
      local back=$(( RANDOM % 4 ))
      info "Backoff ${back}s vor create"
      sleep "$back"
      if volume_exists; then ok "Volume tauchte auf – create übersprungen"; return 0; fi
      if [[ -z "$VOLNAME" ]]; then
        info "VOLNAME leer (Autodetektion ergab nichts) – kein Create im INIT-Modus ohne Namen."
        return 0
      fi
      if [[ "$VTYPE" == "disperse" ]]; then
        info "Create: disperse=$DISPERSE redundancy=$REDUNDANCY"
        run gluster volume create "$VOLNAME" disperse "$DISPERSE" redundancy "$REDUNDANCY" transport tcp "${bricks[@]}" "${maybe_force[@]}"
      else
        info "Create: replica=$REPLICA"
        run gluster volume create "$VOLNAME" replica "$REPLICA" transport tcp "${bricks[@]}" "${maybe_force[@]}"
      fi
      run gluster volume start "$VOLNAME"
      apply_volume_basics
      maybe_profile_workload
      ok "Volume erstellt und gestartet"
    }

    post_join_health(){
      CTX="heal"
      step "Heal/Split-Brain Info"
      run gluster volume heal "$VOLNAME" info >/dev/null 2>&1 || true
      run gluster volume heal "$VOLNAME" split-brain info >/dev/null 2>&1 || true
      info "Heal-Abfrage ausgeführt (Details in gluster-Logs)"
    }

    # ---------------- Main ----------------
    step "Initialisierung"
    start_glusterd
    check_state_dir
    probe_peers
    require_peer_quorum
    reconcile_peers_warn
    autodetect_volume

    case "$MODE" in
      brick)
        CTX="mode-brick"
        step "Modus: BRICK"
        if volume_exists; then
          ensure_volume_started
          apply_volume_basics
          ensure_local_brick
          post_join_health
        else
          if [[ -z "$VOLNAME" ]]; then
            info "Kein Volume sichtbar (Autodetektion) – reiner Brick-Modus."
          else
            info "Kein Volume $VOLNAME bekannt (oder noch nicht synchronisiert)."
          fi
        fi
        ;;
      init)
        CTX="mode-init"
        step "Modus: INIT"
        if volume_exists; then
          info "Volume $VOLNAME existiert bereits."
          ensure_volume_started
          apply_volume_basics
          ensure_local_brick
          post_join_health
        else
          create_volume_safely
        fi
        ;;
      *)
        error "Unbekannter MODE=$MODE"
        exit 1
        ;;
    esac

    CTX="ready"
    ok "Bereit – glusterd läuft. Warte auf Prozessende…"
    wait ${GLUSTERD_PID}
