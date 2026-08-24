# The JIT launcher: `nix run .#permafrost [run|start|stop|status]`.
#
# Everything the guest needs on the host is created at launch and reclaimed when
# the unit stops — the bridge, the NAT rules, one virtiofsd per share, the ssh
# keys harvested from the launching user's agent, and the ephemeral disk images.
# Nothing is left behind on a clean exit, a crash, or a SIGKILL.
{
  pkgs,
  nixos,
  sshConfig,
}:

let
  inherit (pkgs) lib;
  shareLib = import ../_lib/shares.nix;

  cfg = nixos.config.permafrost;
  inherit (cfg) identity;
  inherit (cfg) shares;

  # Host-side home for this guest's ephemeral disk images. Must match stateDir in
  # modules/guest/base.nix, which keys it on the guest's name.
  stateDir = "/var/lib/permafrost/${identity.name}";
in

pkgs.writeShellScriptBin identity.name ''
  set -e
  COMMAND="''${1:-run}"
  [ $# -gt 0 ] && shift

  # 1. Environment Detection
  if [ -n "$SUDO_USER" ]; then
    REAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
  else
    REAL_HOME=$(getent passwd "$USER" | cut -d: -f6)
  fi

  HOST_XDG_RUNTIME_DIR="''${XDG_RUNTIME_DIR:-/run/user/1000}"
  HOST_WAYLAND_DISPLAY="''${WAYLAND_DISPLAY:-wayland-0}"
  if [ ! -S "$HOST_XDG_RUNTIME_DIR/$HOST_WAYLAND_DISPLAY" ]; then
    PROBED_SOCKET=$(ls $HOST_XDG_RUNTIME_DIR/wayland-* 2>/dev/null | head -n1)
    [ -S "$PROBED_SOCKET" ] && HOST_WAYLAND_DISPLAY=$(basename "$PROBED_SOCKET")
  fi

  ${lib.optionalString cfg.gui ''
    # Fail fast rather than hang. microvm.nix's preStart backgrounds
    #   crosvm device gpu --wayland-sock $XDG_RUNTIME_DIR/$WAYLAND_DISPLAY
    # and then spins in `while ! [ -S gpu.sock ]`, so with no compositor to
    # attach to crosvm exits and that loop never terminates.
    if [ ! -S "$HOST_XDG_RUNTIME_DIR/$HOST_WAYLAND_DISPLAY" ]; then
      echo "Error: permafrost.gui is on but no Wayland compositor was found." >&2
      echo "  Looked for: $HOST_XDG_RUNTIME_DIR/$HOST_WAYLAND_DISPLAY" >&2
      echo "  Launch from a graphical session, and use 'sudo -E' so that" >&2
      echo "  XDG_RUNTIME_DIR and WAYLAND_DISPLAY survive into the runner." >&2
      echo "  For a headless host, set permafrost.gui = false in modules/guest/identity.nix." >&2
      exit 1
    fi
  ''}

  # 2. Lifecycle & Path Configuration
  # We use Systemd RuntimeDirectory for "pure" automatic cleanup of all sockets/pids
  RUNTIME_NAME="microvm-${identity.name}"
  SOCKET_DIR="/run/$RUNTIME_NAME"
  UNIT_NAME="microvm-${identity.name}"
  STATE_DIR="${stateDir}"
  BRIDGE="microbr"
  GATEWAY_IP="${identity.gateway}"
  TAP_ID="microvm-${identity.tapId}"

  # 3. JIT Credential Collection
  # We collect keys BEFORE the systemd-run isolation block
  # We use a shared directory pattern recommended by microvm.nix
  SSH_KEYS_DIR="$SOCKET_DIR/ssh-keys"
  mkdir -p "$SSH_KEYS_DIR"
  chmod 755 "$SSH_KEYS_DIR"

  if [ -n "$SUDO_USER" ] && [ -z "$SSH_AUTH_SOCK" ]; then
    # Try to find the user's agent if they forgot sudo -E. The list is
    # ordered by preference and matched exactly rather than by glob:
    # permafrost-agent.sock sits in the same directory and holds the
    # agentic key, so a wildcard could enrol that key for interactive
    # login — and for root — inverting the isolation the two-agent split
    # exists to provide. Only the personal agent belongs here.
    USER_RUNTIME_DIR="/run/user/$(id -u "$SUDO_USER")"
    for CANDIDATE in \
      ssh-tpm-agent.sock \
      gnupg/S.gpg-agent.ssh \
      ssh-agent.socket \
      keyring/ssh; do
      if [ -S "$USER_RUNTIME_DIR/$CANDIDATE" ]; then
        export SSH_AUTH_SOCK="$USER_RUNTIME_DIR/$CANDIDATE"
        echo "Auto-detected SSH agent for $SUDO_USER at $SSH_AUTH_SOCK"
        break
      fi
    done
  fi

  # Whichever agent we ended up with — probed or inherited through
  # sudo -E — decides who can log in, because authorized_keys is just
  # its public halves. The permafrost agent holds only the agentic key,
  # which is not enrolled for interactive login.
  case "$SSH_AUTH_SOCK" in
    */permafrost-agent.sock)
      echo "Warning: SSH_AUTH_SOCK points at the permafrost agent." >&2
      echo "  Only the agentic key will be enrolled in authorized_keys, so your" >&2
      echo "  interactive login will likely be rejected. Launch from a session on" >&2
      echo "  the personal agent (ssh-tpm-agent.sock) instead." >&2
      ;;
  esac

  # For the agent user only. Enrolling these for root as well used to be the
  # convenience path, and it was also a way back to root from inside the
  # guest: the forwarded agent can reach sshd on localhost, so a bare key in
  # root's authorized_keys made `ssh root@localhost` an escalation. Root now
  # authenticates by certificate instead — see modules/guest/ssh-ca.nix — and
  # a certificate is not something the guest can mint for itself.
  if [ -n "$SSH_AUTH_SOCK" ]; then
    ssh-add -L > "$SSH_KEYS_DIR/agent" 2>/dev/null || true
  fi
  if [ -n "$AGENT_PUBKEYS" ]; then
    echo "$AGENT_PUBKEYS" >> "$SSH_KEYS_DIR/agent"
  fi
  chmod 644 "$SSH_KEYS_DIR"/* || true

  # 3b. Host-side client config
  #
  # Installed here rather than left to the operator: it is derived from the
  # same configuration the guest is built from, so writing it at launch is what
  # keeps the two from drifting, and the launching user's uid resolves the
  # agent socket path without anyone having to set a variable.
  #
  # A pre-existing file that we did not write is moved aside, once, rather
  # than clobbered.
  if [ -n "$SUDO_USER" ]; then
    SSH_CONF="$REAL_HOME/.ssh/config.d/13-permafrost.conf"
    SUDO_GROUP=$(id -gn "$SUDO_USER")
    ${pkgs.coreutils}/bin/install -d -o "$SUDO_USER" -g "$SUDO_GROUP" -m 700 \
      "$REAL_HOME/.ssh" "$REAL_HOME/.ssh/config.d"

    SKIP_SSH_CONF=""
    if [ -e "$SSH_CONF" ] && ! ${pkgs.gnugrep}/bin/grep -qF "Managed by nix-permafrost" "$SSH_CONF"; then
      if [ -e "$SSH_CONF.bak" ]; then
        # Backed up once already, so this is a later hand-edit. Losing it
        # silently is worse than leaving the config stale.
        echo "Warning: $SSH_CONF is hand-edited and $SSH_CONF.bak already exists." >&2
        echo "  Leaving both untouched. Delete or restore one of them to let" >&2
        echo "  permafrost manage this file again." >&2
        SKIP_SSH_CONF=1
      else
        ${pkgs.coreutils}/bin/mv "$SSH_CONF" "$SSH_CONF.bak"
        echo "Kept your existing ssh config as $SSH_CONF.bak; permafrost now manages $SSH_CONF." >&2
      fi
    fi

    NEW_CONF=$(${sshConfig}/bin/permafrost-ssh-config "/run/user/$(id -u "$SUDO_USER")")
    if [ -z "$SKIP_SSH_CONF" ] && [ "$NEW_CONF" != "$(${pkgs.coreutils}/bin/cat "$SSH_CONF" 2>/dev/null)" ]; then
      printf '%s\n' "$NEW_CONF" > "$SSH_CONF"
      ${pkgs.coreutils}/bin/chown "$SUDO_USER:$SUDO_GROUP" "$SSH_CONF"
      chmod 600 "$SSH_CONF"
      echo "Updated $SSH_CONF from the guest's configuration."
    fi
  fi

  # 3c. JIT TLS certificate for the guest's web UI.
  #
  # Optional and never fatal. The guest config always carries both paths and
  # decides at boot which one applies: a certificate here means caddy serves
  # it, an empty directory means caddy self-signs exactly as it did before.
  # Nothing about that is expressed in Nix — this is a shell script, so the
  # optionality is shell control flow, the same shape as the agent probe above.
  #
  # Issued here rather than in the guest on purpose. The guest runs coding
  # agents with their sandboxes off; handing it a Vault credential would let
  # anything running in it mint certificates from the intermediate. Issuing on
  # the host means the guest receives one leaf, for one address, and holds no
  # Vault access at all — it never even talks to Vault, which is also why the
  # CA does not have to be added to the guest's trust store.
  #
  # Overridable without a rebuild, because the role's own constraints
  # (allowed_domains, require_cn, allow_ip_sans) live with the CA rather than
  # here, and a mismatch should be a one-line fix rather than a flake edit.
  VAULT_ADDR="''${VAULT_ADDR:-https://vault.service.consul:8200}"
  VAULT_PKI_MOUNT="''${VAULT_PKI_MOUNT:-pki_int_homelab}"
  VAULT_PKI_ROLE="''${VAULT_PKI_ROLE:-home-lan}"
  VAULT_TLS_CN="''${VAULT_TLS_CN:-${identity.name}.home.lan}"
  VAULT_TLS_TTL="''${VAULT_TLS_TTL:-12h}"

  VAULT_TLS_DIR="$SOCKET_DIR/vault-tls"
  VAULT_TLS_SERIAL=""

  # sudo strips VAULT_TOKEN just as it strips SSH_AUTH_SOCK. Fall back to the
  # file the vault CLI itself reads, in the launching user's home.
  resolve_vault_token() {
    if [ -n "''${VAULT_TOKEN:-}" ]; then
      return 0
    fi
    if [ -r "$REAL_HOME/.vault-token" ]; then
      VAULT_TOKEN=$(${pkgs.coreutils}/bin/cat "$REAL_HOME/.vault-token" 2>/dev/null || true)
    fi
  }

  issue_vault_tls() {
    resolve_vault_token

    if [ -z "''${VAULT_TOKEN:-}" ]; then
      echo "No Vault token found; the guest will self-sign its web UI certificate." >&2
      echo "  Run 'vault login' for a browser-trusted one." >&2
      return 0
    fi

    RESPONSE=$(${pkgs.curl}/bin/curl -sS --max-time 15 \
      -H "X-Vault-Token: $VAULT_TOKEN" \
      -X POST \
      -d "{\"common_name\":\"$VAULT_TLS_CN\",\"ip_sans\":\"${identity.ip}\",\"ttl\":\"$VAULT_TLS_TTL\"}" \
      "$VAULT_ADDR/v1/$VAULT_PKI_MOUNT/issue/$VAULT_PKI_ROLE" 2>&1) || {
      echo "Vault unreachable; the guest will self-sign its web UI certificate." >&2
      return 0
    }

    if ! echo "$RESPONSE" | ${pkgs.jq}/bin/jq -e '.data.private_key' >/dev/null 2>&1; then
      echo "Vault refused to issue a certificate; the guest will self-sign." >&2
      echo "  $(echo "$RESPONSE" | ${pkgs.jq}/bin/jq -rc '.errors // .' 2>/dev/null || echo "$RESPONSE")" >&2
      echo "  Check: vault read $VAULT_PKI_MOUNT/roles/$VAULT_PKI_ROLE" >&2
      return 0
    fi

    # Leaf first, then the chain, in one file — caddy wants the bundle.
    echo "$RESPONSE" | ${pkgs.jq}/bin/jq -r '.data.certificate, (.data.ca_chain // [] | .[])' \
      > "$VAULT_TLS_DIR/cert.pem"
    echo "$RESPONSE" | ${pkgs.jq}/bin/jq -r '.data.private_key' > "$VAULT_TLS_DIR/key.pem"
    VAULT_TLS_SERIAL=$(echo "$RESPONSE" | ${pkgs.jq}/bin/jq -r '.data.serial_number')
    echo "$VAULT_TLS_SERIAL" > "$VAULT_TLS_DIR/serial"

    chmod 0644 "$VAULT_TLS_DIR/cert.pem" "$VAULT_TLS_DIR/serial"
    chmod 0600 "$VAULT_TLS_DIR/key.pem"

    echo "Issued a web UI certificate from $VAULT_PKI_MOUNT/$VAULT_PKI_ROLE (ttl $VAULT_TLS_TTL)."
  }

  # Best-effort, and deliberately so: a stolen leaf for a host-local bridge
  # address is already bounded by its ttl, and browsers routinely skip CRL and
  # OCSP for private CAs. This is Vault-side hygiene, not enforcement.
  revoke_vault_tls() {
    SERIAL="''${1:-}"
    [ -n "$SERIAL" ] || return 0
    resolve_vault_token
    [ -n "''${VAULT_TOKEN:-}" ] || return 0

    ${pkgs.curl}/bin/curl -sS --max-time 10 \
      -H "X-Vault-Token: $VAULT_TOKEN" \
      -X POST \
      -d "{\"serial_number\":\"$SERIAL\"}" \
      "$VAULT_ADDR/v1/$VAULT_PKI_MOUNT/revoke" >/dev/null 2>&1 \
      && echo "Revoked web UI certificate $SERIAL." \
      || true
  }

  case "$COMMAND" in
    status)
      if systemctl is-active --quiet "$UNIT_NAME"; then
        echo "Status: RUNNING"
        echo "IP:     ${identity.ip}"
        echo "CID:    ${toString identity.vsockCid}"
        echo "Runtime: $SOCKET_DIR"
      else
        echo "Status: STOPPED"
      fi
      exit 0
      ;;
    stop)
      # Read the serial before stopping: the runtime directory holding it goes
      # away with the unit, and revoking a certificate we can no longer name
      # is not possible.
      if [ -r "$VAULT_TLS_DIR/serial" ]; then
        STOPPING_SERIAL=$(${pkgs.coreutils}/bin/cat "$VAULT_TLS_DIR/serial" 2>/dev/null || true)
      else
        STOPPING_SERIAL=""
      fi
      echo "Stopping $UNIT_NAME..."
      systemctl stop "$UNIT_NAME"
      revoke_vault_tls "$STOPPING_SERIAL"
      exit 0
      ;;
    run|start)
      # Take the lock before the is-active check, otherwise two concurrent
      # launches can both pass the check and then race the preStart wipe of
      # the disk images. The fd is held for the life of the script.
      ${pkgs.coreutils}/bin/mkdir -p "$STATE_DIR"
      exec 9>"$STATE_DIR/.lock"
      if ! ${pkgs.util-linux}/bin/flock -n 9; then
        echo "Error: another launch of ${identity.name} is already in progress."
        exit 1
      fi
      if systemctl is-active --quiet "$UNIT_NAME"; then
        echo "Error: $UNIT_NAME is already running."
        exit 1
      fi

      # Always created, even when issuance does not happen: the share is
      # declared unconditionally in the guest, so the directory behind it has
      # to exist. Empty is how the guest learns to self-sign instead.
      mkdir -p "$VAULT_TLS_DIR"
      chmod 700 "$VAULT_TLS_DIR"
      issue_vault_tls
      ;;
    *)
      echo "Usage: $0 {run|start|stop|status}"
      exit 1
      ;;
  esac

  echo "Initializing Pure Sandbox Lifecycle for ${identity.name}..."
  echo "Runtime Directory: $SOCKET_DIR"

  # 3. JIT Networking Setup
  if ! ip link show "$BRIDGE" >/dev/null 2>&1; then
    ip link add name "$BRIDGE" type bridge
    ip addr add "$GATEWAY_IP/24" dev "$BRIDGE"
    ip link set "$BRIDGE" up
  fi

  ${pkgs.procps}/bin/sysctl -w net.ipv4.ip_forward=1 >/dev/null
  EXT_IF=$(ip route | grep default | awk '{print $5}' | head -n1)

  # Idempotent NAT — check-then-add, and rules are never removed on cleanup, so
  # a second launch neither duplicates them nor tears down a live one.
  if [ -n "$EXT_IF" ]; then
    ${pkgs.iptables}/bin/iptables -t nat -C POSTROUTING -s 192.168.33.0/24 -o "$EXT_IF" -j MASQUERADE 2>/dev/null || \
      ${pkgs.iptables}/bin/iptables -t nat -A POSTROUTING -s 192.168.33.0/24 -o "$EXT_IF" -j MASQUERADE
    ${pkgs.iptables}/bin/iptables -C FORWARD -i "$BRIDGE" -j ACCEPT 2>/dev/null || \
      ${pkgs.iptables}/bin/iptables -A FORWARD -i "$BRIDGE" -j ACCEPT
    ${pkgs.iptables}/bin/iptables -C FORWARD -o "$BRIDGE" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
      ${pkgs.iptables}/bin/iptables -A FORWARD -o "$BRIDGE" -m state --state RELATED,ESTABLISHED -j ACCEPT
  fi

  # NOTE: image cleanup is NOT done here. A shell trap only fires in "run" mode
  # and never on SIGKILL or host power loss. It is an ExecStopPost property on
  # the unit instead (see RUN_ARGS), which systemd runs whenever the unit stops.

  # Background TAP attachment
  (
    for i in {1..100}; do
      if ip link show "$TAP_ID" >/dev/null 2>&1; then
        ip link set "$TAP_ID" master "$BRIDGE"
        ip link set "$TAP_ID" up
        break
      fi
      sleep 0.1
    done
  ) &

  # 4. Process Launch Wrapper
  # We wrap everything in a systemd-run service to ensure RuntimeDirectory cleanup works
  # regardless of how the script or VM exits.

  LAUNCH_COMMAND='
    # Start virtiofsd backends
    ${pkgs.virtiofsd}/bin/virtiofsd --socket-path "'$SOCKET_DIR'/ro-store.sock" --shared-dir /nix/store --sandbox namespace &
    ${pkgs.virtiofsd}/bin/virtiofsd --socket-path "'$SOCKET_DIR'/ssh.sock" --shared-dir "'$SSH_KEYS_DIR'" --sandbox namespace &
    ${pkgs.virtiofsd}/bin/virtiofsd --socket-path "'$SOCKET_DIR'/vault-tls.sock" --shared-dir "'$VAULT_TLS_DIR'" --sandbox namespace &

    ${lib.concatMapStringsSep "\n" (s: ''
      ${pkgs.coreutils}/bin/mkdir -p "$REAL_HOME/${s.host}"
      ${pkgs.virtiofsd}/bin/virtiofsd --socket-path "$SOCKET_DIR/${shareLib.tag s}.sock" --shared-dir "$REAL_HOME/${s.host}" --sandbox namespace &
    '') shares}

    # Wait for backend readiness
    echo "Waiting for virtiofsd backends..."
    while [ ! -S "$SOCKET_DIR/ro-store.sock" ]; do ${pkgs.coreutils}/bin/sleep 0.1; done
    while [ ! -S "$SOCKET_DIR/ssh.sock" ]; do ${pkgs.coreutils}/bin/sleep 0.1; done
    while [ ! -S "$SOCKET_DIR/vault-tls.sock" ]; do ${pkgs.coreutils}/bin/sleep 0.1; done
    ${lib.concatMapStringsSep "\n" (
      s: ''while [ ! -S "$SOCKET_DIR/${shareLib.tag s}.sock" ]; do ${pkgs.coreutils}/bin/sleep 0.1; done''
    ) shares}

    # Final VM Launch.
    #
    # No socket flags here: microvm.nix bakes them into microvm-run and that
    # script never forwards "$@" — it sets `runtime_args=` and leaves it
    # empty — so anything passed is silently dropped. The baked paths are
    # relative (`--api-socket permafrost.sock`, `--vsock ...socket=notify.vsock`),
    # which is why the unit sets WorkingDirectory below. Without it they
    # resolved against / and littered the host filesystem root.
    ${nixos.config.microvm.declaredRunner}/bin/microvm-run
  '

  RUN_ARGS=(
    --unit="$UNIT_NAME"
    --collect
    --service-type=exec
    --property="RuntimeDirectory=$RUNTIME_NAME"
    --property="RuntimeDirectoryPreserve=no"
    # microvm-run's baked socket paths are relative, so this is what decides
    # where they land. Pointing it at the RuntimeDirectory means they are
    # reclaimed with it rather than accumulating at /.
    --property="WorkingDirectory=$SOCKET_DIR"
    --property="Environment=PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.bash
        pkgs.util-linux
        pkgs.openssh
      ]
    }"
    --property="Environment=REAL_HOME=$REAL_HOME"
    --property="Environment=HOST_XDG_RUNTIME_DIR=$HOST_XDG_RUNTIME_DIR"
    --property="Environment=HOST_WAYLAND_DISPLAY=$HOST_WAYLAND_DISPLAY"
    # microvm.nix's cloud-hypervisor preStart runs
    #   crosvm device gpu --wayland-sock $XDG_RUNTIME_DIR/$WAYLAND_DISPLAY
    # verbatim, so it needs those exact names, not the HOST_* copies. The
    # unit runs as root, which can traverse the invoking user's 0700
    # /run/user/<uid>.
    --property="Environment=XDG_RUNTIME_DIR=$HOST_XDG_RUNTIME_DIR"
    --property="Environment=WAYLAND_DISPLAY=$HOST_WAYLAND_DISPLAY"
    --property="Environment=SOCKET_DIR=$SOCKET_DIR"
    --property="Environment=RUNTIME_NAME=$RUNTIME_NAME"
    --property="Environment=SSH_KEYS_DIR=$SSH_KEYS_DIR"
    --property="Environment=VAULT_TLS_DIR=$VAULT_TLS_DIR"
    --property="Environment=AGENT_PUBKEYS=$AGENT_PUBKEYS"
    --description="Permafrost VM: ${identity.name}"
    # Reclaim the ephemeral disk images whenever the unit stops — clean exit,
    # crash, or SIGKILL — in both run and start modes. preStart also wipes on
    # the next boot, so a host power loss leaves at most one stale image set,
    # reclaimed on the next launch or by `nix run .#gc`.
    --property="ExecStopPost=${pkgs.coreutils}/bin/rm -rf $STATE_DIR"
    # Ask the guest to shut down instead of cutting its power. microvm.nix
    # ships this client: it PUTs vm.power-button on the hypervisor API socket
    # and then waits on $MAINPID, which systemd sets for ExecStop. The guest
    # has the matching ACPI button (PNP0C0C) and logind's default
    # HandlePowerKey=poweroff turns it into a real shutdown.
    #
    # Bounded rather than left at systemd's 90s default: if the guest ignores
    # the button, the normal SIGTERM/SIGKILL escalation still ends it, and
    # there is no reason to wait a minute and a half to find that out.
    --property="ExecStop=${nixos.config.microvm.declaredRunner}/bin/microvm-shutdown"
    --property="TimeoutStopSec=45s"
  )

  if [ "$COMMAND" = "run" ]; then
    # --wait blocks until the guest is gone, so this is the run-mode equivalent
    # of what the stop subcommand does. The serial is held in a variable rather
    # than read back from disk: the runtime directory is already gone by the
    # time this line runs.
    systemd-run --pty --wait "''${RUN_ARGS[@]}" ${pkgs.bash}/bin/bash -c "$LAUNCH_COMMAND" || true
    revoke_vault_tls "$VAULT_TLS_SERIAL"
  else
    systemd-run "''${RUN_ARGS[@]}" ${pkgs.bash}/bin/bash -c "$LAUNCH_COMMAND"
    echo "${identity.name} started in background (unit: $UNIT_NAME)."
  fi
''
