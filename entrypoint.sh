\
    #!/usr/bin/env bash
    set -Eeuo pipefail

    info(){ printf '%s [INFO] %s\n' "$(date -u +%FT%TZ)" "$*"; }
    warn(){ printf '%s [WARN] %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }
    err(){ printf '%s [ERROR] %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }

    # Defaults
    : "${DATA_PORT_START:=49152}"
    : "${MAX_PORT:=49251}"
    : "${ADDRESS_FAMILY:=inet}"             # inet|inet6
    : "${VOLNAME:=gv0}"
    : "${REPLICA:=2}"
    : "${TRANSPORT:=tcp}"
    : "${AUTH_ALLOW:=10.0.0.0/8,172.16.0.0/12,192.168.0.0/16}"
    : "${NFS_DISABLE:=1}"
    : "${HOSTNAME_GLUSTER:=gluster-solo}"

    pick_primary_ipv4(){
      ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | head -n1
    }

    is_ipv4(){
      [[ "${1:-}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
    }

    ensure_hosts_mapping(){
      local cip
      cip="$(pick_primary_ipv4 || true)"
      if [[ -n "$cip" ]]; then
        # map our hostname to our container IP so Gluster sees us as a local peer
        if ! getent hosts "$(hostname -s)" >/dev/null 2>&1; then
          echo "$cip $(hostname -s)" >> /etc/hosts || true
        fi
      fi
    }

    ensure_glusterd_vol(){
      install -d -m 0755 /etc/glusterfs
      cat > /etc/glusterfs/glusterd.vol <<EOF
    volume management
        type mgmt/glusterd
        option working-directory /var/lib/glusterd
        option transport.address-family ${ADDRESS_FAMILY}
        option base-port ${DATA_PORT_START}
    end-volume
    EOF
    }

    start_glusterd(){
      ensure_hosts_mapping
      ensure_glusterd_vol
      info "starting glusterd (foreground, -N)"
      /usr/sbin/glusterd -N &
      GLUSTERD_PID=$!
      trap 'kill ${GLUSTERD_PID} 2>/dev/null || true' EXIT
      # wait until responsive
      for i in {1..60}; do
        if gluster --mode=script volume info >/dev/null 2>&1; then
          return 0
        fi
        sleep 0.5
      done
      err "glusterd did not become ready"
      return 1
    }

    resolve_brick_host(){
      local cand="${BRICK_HOST:-}"
      # If not provided, try what glusterd thinks
      if [[ -z "$cand" ]] && [[ -f /var/lib/glusterd/glusterd.info ]]; then
        cand="$(grep -E '^hostname=' /var/lib/glusterd/glusterd.info | head -n1 | cut -d= -f2)"
      fi
      # Then try logical hostname
      if [[ -z "$cand" ]]; then cand="${HOSTNAME_GLUSTER}"; fi
      # As a last resort, fall back to IP (we will rewrite if it's our own IP)
      if [[ -z "$cand" ]]; then cand="$(pick_primary_ipv4 || true)"; fi

      # If cand is exactly our own primary IPv4, Gluster will not see it as a local peer -> use hostname
      local prim; prim="$(pick_primary_ipv4 || true)"
      if [[ -n "$prim" ]] && [[ "$cand" == "$prim" ]]; then
        cand="$(hostname -s)"
      fi

      if [[ -z "$cand" ]]; then
        err "Could not determine BRICK_HOST"; return 1
      fi
      printf '%s\n' "$cand"
    }

    create_volume_if_missing(){
      local host; host="$(resolve_brick_host)"
      info "using BRICK_HOST=${host}"
      # prepare bricks
      install -d -m 0755 /bricks/brick1 /bricks/brick2
      chown -R root:root /bricks

      if gluster volume info "${VOLNAME}" >/dev/null 2>&1; then
        info "volume ${VOLNAME} exists"
      else
        info "creating: gluster volume create ${VOLNAME} replica ${REPLICA} transport ${TRANSPORT} ${host}:/bricks/brick1 ${host}:/bricks/brick2 force"
        if ! gluster volume create "${VOLNAME}" replica "${REPLICA}" transport "${TRANSPORT}" \
             "${host}:/bricks/brick1" "${host}:/bricks/brick2" force; then
          err "volume create failed"; return 1
        fi
      fi

      gluster volume set "${VOLNAME}" auth.allow "${AUTH_ALLOW}" || true
      [[ "${NFS_DISABLE}" == "1" ]] && gluster volume set "${VOLNAME}" nfs.disable on || true

      info "starting volume ${VOLNAME}"
      gluster volume start "${VOLNAME}" || true
    }

    main(){
      start_glusterd
      create_volume_if_missing
      wait "${GLUSTERD_PID}"
    }

    main "$@"
