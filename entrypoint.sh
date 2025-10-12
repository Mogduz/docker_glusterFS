\
    #!/usr/bin/env bash
    # GlusterFS server entrypoint (verbose + autodetect + peer-wait + multi-brick)
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
    _log(){
  local lvl="${1:-INFO}"; shift || true
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
    VTYPE="${VTYPE:-replica}"                    # replica | disperse
    REPLICA="${REPLICA:-3}"
    DISPERSE="${DISPERSE:-6}"                    # VTYPE=disperse (data)
    REDUNDANCY="${REDUNDANCY:-2}"                # VTYPE=disperse (redundancy)
    BRICK_PATH="${BRICK_PATH:-/bricks/brick1}"
    BRICK_PATHS="${BRICK_PATHS:-}"               # comma-separated for multi-brick
    PEERS="${PEERS:-}"
    AUTO_ADD_BRICK="${AUTO_ADD_BRICK:-0}"        # safe only for REPLICA=1
    ADD_BRICK_SET="${ADD_BRICK_SET:-}"           # comma-separated hosts; used to add full replica sets
    ALLOW_FORCE_CREATE="${ALLOW_FORCE_CREATE:-0}"
    ALLOW_EMPTY_STATE="${ALLOW_EMPTY_STATE:-0}"
    REQUIRE_ALL_PEERS="${REQUIRE_ALL_PEERS:-1}"
    REQUIRE_MOUNTED_BRICK="${REQUIRE_MOUNTED_BRICK:-0}"
    ADDRESS_FAMILY="${ADDRESS_FAMILY:-}"
    PORT_RANGE="${PORT_RANGE:-49152-49251}"
    LOG_LEVEL="${LOG_LEVEL:-WARNING}"
    ENABLE_SSL="${ENABLE_SSL:-0}"
    VOLUME_PROFILE="${VOLUME_PROFILE:-}"         # e.g., vm
    PEER_WAIT_SECS="${PEER_WAIT_SECS:-120}"      # -1=infinite, 0=no-wait, >0 seconds
    PEER_WAIT_INTERVAL="${PEER_WAIT_INTERVAL:-1}"
    DRY_RUN="${DRY_RUN:-0}"                      # 1=log commands only

    step "Startparameter"
{
  printf '  MODE=%s\n' "$MODE"
  printf '  VOLNAME=%s\n' "$VOLNAME"
  printf '  VTYPE=%s\n' "$VTYPE"
  printf '  REPLICA=%s\n' "$REPLICA"
  printf '  DISPERSE=%s\n' "$DISPERSE"
  printf '  REDUNDANCY=%s\n' "$REDUNDANCY"
  printf '  BRICK_PATH=%s\n' "$BRICK_PATH"
  printf '  BRICK_PATHS=%s\n' "${BRICK_PATHS:-<leer>}"
  printf '  PEERS=%s\n' "$PEERS"
  printf '  REQUIRE_ALL_PEERS=%s\n' "$REQUIRE_ALL_PEERS"
  printf '  ADDRESS_FAMILY=%s\n' "${ADDRESS_FAMILY:-unset}"
  printf '  PORT_RANGE=%s\n' "$PORT_RANGE"
  printf '  LOG_LEVEL=%s\n' "$LOG_LEVEL"
  printf '  TRACE=%s\n' "$TRACE"
  printf '  PEER_WAIT_SECS=%s\n' "$PEER_WAIT_SECS"
  printf '  PEER_WAIT_INTERVAL=%s\n' "$PEER_WAIT_INTERVAL"
  printf '  DRY_RUN=%s\n' "$DRY_RUN"
}
    # -------- Helpers --------
    to_arr(){ IFS=',' read -ra _ARR <<< "$1"; }
    run(){ info "RUN: $*"; if [[ "$DRY_RUN" -eq 1 ]]; then return 0; else "$@"; fi; }
    brick_paths(){
      if [[ -n "$BRICK_PATHS" ]]; then IFS="," read -ra _BPATHS <<< "$BRICK_PATHS"; else _BPATHS=("$BRICK_PATH"); fi
    }
    require_cmd(){ command -v "$1" >/dev/null || { error "Binary fehlt: $1"; return 127; }; }

    start_glusterd(){
      CTX="glusterd"
      step "glusterd starten"
      require_cmd glusterd
      brick_paths
      for p in "${_BPATHS[@]}"; do
        mkdir -p "$p"
        if [[ "$REQUIRE_MOUNTED_BRICK" -eq 1 ]] && ! mountpoint -q "$p"; then
          error "Brick-Pfad ist kein Mountpoint: $p"; return 3
        fi
        touch "$p/.glusterfs_brick" 2>/dev/null || { error "Brick-Pfad nicht beschreibbar: $p"; return 4; }
      done
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
      local pool; pool=$(gluster pool list 2>/dev/null | awk \'NR>1 && $1 !~ /Number/ && NF>=3 {print $3}\' || true)
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
      run gluster --mode=script volume start "$VOLNAME"
      ok "Volume gestartet"
    }

    ensure_local_bricks(){
      CTX="brick-verify"
      step "Lokale Bricks prüfen"
      brick_paths
      if [[ -z "$VOLNAME" ]]; then info "Kein VOLNAME gesetzt → übersprungen"; return 0; fi
      local self; self="$(hostname -s)"
      local missing=()
      for p in "${_BPATHS[@]}"; do
        if gluster volume info "$VOLNAME" 2>/dev/null | grep -qE "Brick[0-9]+: $self:$p"; then
          info "Brick vorhanden: $self:$p"
        else
          missing+=("$self:$p")
        fi
      done
      if (( ${#missing[@]} == 0 )); then ok "Alle lokalen Bricks sind Teil von $VOLNAME"; return 0; fi

      if [[ "$AUTO_ADD_BRICK" -eq 1 && "$REPLICA" -eq 1 ]]; then
        for bp in "${missing[@]}"; do
          info "Füge fehlenden Brick hinzu (REPLICA=1): $bp"
          run gluster volume add-brick "$VOLNAME" "$bp"
        done
        warn "Rebalance/Heal empfohlen"
        return 0
      fi

      if [[ -n "$ADD_BRICK_SET" ]]; then
        IFS=',' read -ra hosts <<< "$ADD_BRICK_SET"
        local n=${#hosts[@]}
        if (( n % REPLICA != 0 )); then
          warn "ADD_BRICK_SET-Größe ($n) ist kein Vielfaches von REPLICA ($REPLICA) – übersprungen"
          return 0
        fi
        for p in "${_BPATHS[@]}"; do
          if printf '%s\n' "${missing[@]}" | grep -q "$self:$p"; then
            local bricks=()
            for h in "${hosts[@]}"; do bricks+=("${h}:$p"); done
            info "Add-brick (replica $REPLICA) für Pfad $p über Hosts: ${hosts[*]}"
            run gluster volume add-brick "$VOLNAME" replica "$REPLICA" "${bricks[@]}"
            warn "Rebalance/Heal empfohlen"
          fi
        done
        return 0
      fi

      warn "Nicht alle lokalen Bricks sind Teil des Volumes: ${missing[*]} (keine Automatik ausgeführt)"
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
      if [[ -z "$VOLNAME" ]]; then info "VOLNAME leer (Autodetektion ergab nichts) – kein Create."; return 0; fi
      to_arr "$PEERS"; local peers=("${_ARR[@]}")
      if (( ${#peers[@]} == 0 )); then error "Keine PEERS definiert – kein create möglich"; return 1; fi

      brick_paths
      local bricks=()
      for p in "${_BPATHS[@]}"; do
        for h in "${peers[@]}"; do bricks+=("${h}:${p}"); done
      done
      local total=${#bricks[@]}

      local maybe_force=(); [[ "$ALLOW_FORCE_CREATE" -eq 1 ]] && maybe_force=("force")

      local back=$(( RANDOM % 4 ))
      info "Backoff ${back}s vor create"
      sleep "$back"
      if volume_exists; then ok "Volume tauchte auf – create übersprungen"; return 0; fi

      if [[ "$VTYPE" == "disperse" ]]; then
        local width=$(( DISPERSE + REDUNDANCY ))
        if (( total % width != 0 )); then
          error "Anzahl Bricks ($total) ist kein Vielfaches von (DISPERSE+REDUNDANCY)=$width"
          return 1
        fi
        info "Create: disperse=$DISPERSE redundancy=$REDUNDANCY, bricks=$total"
        run gluster --mode=script volume create "$VOLNAME" transport tcp disperse "$DISPERSE" redundancy "$REDUNDANCY" "${bricks[@]}" "${maybe_force[@]}"
      else
        if (( total % REPLICA != 0 )); then
          error "Anzahl Bricks ($total) ist kein Vielfaches von REPLICA=$REPLICA"
          return 1
        fi
        info "Create: replica=$REPLICA, bricks=$total"
        run gluster --mode=script volume create "$VOLNAME" transport tcp replica "$REPLICA" "${bricks[@]}" "${maybe_force[@]}"
      fi
      run gluster --mode=script volume start "$VOLNAME"
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
          ensure_local_bricks
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
          ensure_local_bricks
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
