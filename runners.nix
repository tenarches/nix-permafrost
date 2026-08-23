{ inputs, system, ... }:

let
  pkgs = import inputs.nixpkgs {
    inherit system;
    config.allowUnfree = true;
    overlays = [
      # Centralized Python MCP overrides
      (import ./overlays/python-mcp.nix)
      # MCP server packages — evaluated against patched pkgs
      inputs.mcp-servers-nix.overlays.default
    ];
  };
  vms = import ./modules/inventory.nix {
    inherit inputs pkgs;
    inherit (pkgs.stdenv.hostPlatform) system;
  };
  inherit (pkgs) lib;

  # Host-side vhost-user GPU device for microvm.graphics.
  #
  # Two constraints pull in opposite directions. The vhost-user dialect must
  # match the Spectrum-patched cloud-hypervisor, which only the pinned
  # nixpkgs-crosvm still speaks (see flake.nix). But that crosvm is linked
  # against glibc 2.40, while the host's Mesa is built against 2.42 and needs
  # GLIBC_ABI_GNU2_TLS — so when crosvm's Mesa loader follows the NixOS-baked
  # /run/opengl-driver path it fails to open the driver, rutabaga falls back
  # from virglrenderer to a 2D backend, and the guest ends up with no capsets
  # at all ("invalid capset id 4294967295"). That kills the cross-domain
  # context wayland-proxy-virtwl needs.
  #
  # So point the loader at the Mesa from crosvm's own generation, which is ABI
  # compatible with it. Nothing else on the host is affected: the environment
  # is set on this binary only, not on the unit.
  crosvmGraphics =
    let
      cpkgs = inputs.nixpkgs-crosvm.legacyPackages.${system};
    in
    cpkgs.symlinkJoin {
      name = "crosvm-graphics";
      paths = [ cpkgs.crosvm ];
      nativeBuildInputs = [ cpkgs.makeWrapper ];
      # Every one of these has a NixOS-baked /run/opengl-driver default that
      # would pull in the host's Mesa: GBM_BACKENDS_PATH for the gbm backend
      # (the one that actually failed, since dri_gbm.so pulls its own
      # libgallium), __EGL_VENDOR_LIBRARY_FILENAMES for glvnd's EGL vendor
      # discovery, and VK_DRIVER_FILES for the Vulkan ICDs — `vulkan: true` is
      # in the params microvm.nix passes.
      postBuild = ''
        # All of this generation's ICDs, so the host's actual GPU driver is
        # still chosen rather than forcing software Vulkan.
        vkIcds=$(echo ${cpkgs.mesa}/share/vulkan/icd.d/*.json | tr ' ' ':')
        wrapProgram $out/bin/crosvm \
          --set GBM_BACKENDS_PATH ${cpkgs.mesa}/lib/gbm \
          --set LIBGL_DRIVERS_PATH ${cpkgs.mesa}/lib/dri \
          --set __EGL_VENDOR_LIBRARY_FILENAMES ${cpkgs.mesa}/share/glvnd/egl_vendor.d/50_mesa.json \
          --set VK_DRIVER_FILES "$vkIcds" \
          --prefix LD_LIBRARY_PATH : ${
            cpkgs.lib.makeLibraryPath [
              cpkgs.mesa
              cpkgs.libgbm
            ]
          }
      '';
    };

  mkRunner =
    spec:
    let
      # NOTE: the host's ~/workspace is deliberately NOT shared. Each guest gets a
      # private ephemeral workspace on its own home volume instead, so no host
      # directory is reachable from more than one VM.
      globalShares = [
        {
          host = ".agents";
          guest = ".agents";
        }
      ];
      allShares = globalShares ++ (spec.persistentShares or [ ]);

      nixosConfig = inputs.nixpkgs.lib.nixosSystem {
        specialArgs = { inherit inputs; };
        modules = [
          inputs.microvm.nixosModules.microvm
          ./modules/agent-base.nix
          (
            { lib, ... }:
            {
              nixpkgs = {
                hostPlatform.system = system;
                config.allowUnfree = true;
                overlays = [
                  (import ./overlays/python-mcp.nix)
                  inputs.mcp-servers-nix.overlays.default
                ]
                # microvm.cloud-hypervisor.package defaults to
                # pkgs.cloud-hypervisor-graphics (Spectrum's fork, the only build
                # that speaks vhost-user-gpu) once graphics are on. That comes
                # from microvm.nix's own overlay, which this wraps with the fixups
                # it currently needs — see the comment in that file.
                ++ (lib.optionals (spec.gui or false) (
                  import ./overlays/cloud-hypervisor-graphics.nix {
                    microvmOverlay = inputs.microvm.overlay;
                  }
                ))
                ++ (spec.overlays or [ ]);
              };
              microvm = {
                vsock.cid = spec.vsockCid;

                # Host half of the GUI path: microvm.nix's cloud-hypervisor
                # preStart launches `crosvm device gpu` against this socket and
                # the invoking session's compositor. The upstream default is a
                # *relative* path, resolved against the runner's cwd, so pin it
                # into the unit's RuntimeDirectory.
                graphics = lib.optionalAttrs (spec.gui or false) {
                  enable = true;
                  socket = "/run/microvm-${spec.name}/gpu.sock";
                  # Pinned: must match the fork's vhost-user dialect. See the
                  # nixpkgs-crosvm comment in flake.nix.
                  crosvmPackage = crosvmGraphics;
                };
                interfaces = [
                  {
                    type = "tap";
                    id = "microvm-" + spec.tapId;
                    inherit (spec) mac;
                  }
                ];

                shares = lib.mkForce (
                  [
                    {
                      tag = "ro-store";
                      proto = "virtiofs";
                      source = "/nix/store";
                      mountPoint = "/nix/.ro-store";
                      socket = "/run/microvm-${spec.name}/ro-store.sock";
                    }
                    {
                      tag = "ssh_keys";
                      proto = "virtiofs";
                      source = "host-managed-virtiofsd-at-ssh";
                      mountPoint = "/etc/ssh/authorized_keys.d";
                      socket = "/run/microvm-${spec.name}/ssh.sock";
                    }
                  ]
                  ++ (map (s: {
                    source = "host-managed-virtiofsd-at-${s.host}";
                    mountPoint = "/mnt/persist/${s.guest}";
                    # Hash the guest path to stay within the 36-char virtiofs tag limit
                    tag = "p_" + (builtins.substring 0 30 (builtins.hashString "md5" s.guest));
                    proto = "virtiofs";
                    socket =
                      "/run/microvm-${spec.name}/p_"
                      + (builtins.substring 0 30 (builtins.hashString "md5" s.guest))
                      + ".sock";
                  }) allShares)
                );
              };

              # GUI env vars live in modules/graphics.nix, keyed off
              # microvm.graphics.enable.
              environment.variables = spec.env or { };

              # Match any virtio network interface
              systemd.network.networks."10-lan" = {
                matchConfig.Name = "en*";
                address = [ "${spec.ip}/24" ];
                gateway = [ "192.168.33.1" ];
                # Internal resolvers only — see modules/agent-base.nix for why a
                # public resolver must not appear alongside them.
                dns = [
                  "10.0.7.15"
                  "10.0.7.16"
                ];
                networkConfig.IPv6AcceptRA = false;
              };
              networking.hostName = spec.name;
              networking.useNetworkd = true;

              environment.systemPackages = spec.extraPackages;

              home-manager.users.agent.home.file = spec.homeFiles or { };

              # Dynamically map persistent shares into /home/agent
              systemd.tmpfiles.rules =
                (map (s: "L+ /home/agent/${s.guest} - - - - /mnt/persist/${s.guest}") (
                  spec.persistentShares or [ ]
                ))
                ++ (map (s: "d /mnt/persist/${s.guest} 0700 agent users - -") (spec.persistentShares or [ ]))
                ++ (lib.concatMap (
                  s:
                  lib.optional (
                    s ? guestLink
                  ) "L+ /home/agent/${s.guestLink} - - - - /mnt/persist/${s.guest}/${builtins.baseNameOf s.guestLink}"
                ) (spec.persistentShares or [ ]));
            }
          )
        ]
        # Per-guest NixOS config. Same list the fleet path appends in
        # modules/agents.nix, so a guest is identical either way it is launched.
        ++ (spec.extraModules or [ ]);
      };

      runnerScript = pkgs.writeShellScriptBin spec.name ''
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

        ${lib.optionalString (spec.gui or false) ''
          # Fail fast rather than hang. microvm.nix's preStart backgrounds
          #   crosvm device gpu --wayland-sock $XDG_RUNTIME_DIR/$WAYLAND_DISPLAY
          # and then spins in `while ! [ -S gpu.sock ]`, so with no compositor to
          # attach to crosvm exits and that loop never terminates.
          if [ ! -S "$HOST_XDG_RUNTIME_DIR/$HOST_WAYLAND_DISPLAY" ]; then
            echo "Error: ${spec.name} has gui = true but no Wayland compositor was found." >&2
            echo "  Looked for: $HOST_XDG_RUNTIME_DIR/$HOST_WAYLAND_DISPLAY" >&2
            echo "  Launch from a graphical session, and use 'sudo -E' so that" >&2
            echo "  XDG_RUNTIME_DIR and WAYLAND_DISPLAY survive into the runner." >&2
            echo "  For a headless host, set gui = false on this spec in modules/inventory.nix." >&2
            exit 1
          fi
        ''}

        # 2. Lifecycle & Path Configuration
        # We use Systemd RuntimeDirectory for "pure" automatic cleanup of all sockets/pids
        RUNTIME_NAME="microvm-${spec.name}"
        SOCKET_DIR="/run/$RUNTIME_NAME"
        UNIT_NAME="microvm-${spec.name}"
        # Host-side home for this VM's ephemeral disk images. Must match stateDir in
        # modules/agent-base.nix, which keys it on the guest's hostName.
        STATE_DIR="/var/lib/permafrost/${spec.name}"
        BRIDGE="microbr"
        GATEWAY_IP="192.168.33.1"
        TAP_ID="microvm-${spec.tapId}"

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

        # Extract keys for both agent and root
        if [ -n "$SSH_AUTH_SOCK" ]; then
          ssh-add -L > "$SSH_KEYS_DIR/agent" 2>/dev/null || true
          cp "$SSH_KEYS_DIR/agent" "$SSH_KEYS_DIR/root" || true
        fi
        if [ -n "$AGENT_PUBKEYS" ]; then
          echo "$AGENT_PUBKEYS" >> "$SSH_KEYS_DIR/agent"
          echo "$AGENT_PUBKEYS" >> "$SSH_KEYS_DIR/root"
        fi
        chmod 644 "$SSH_KEYS_DIR"/* || true

        # 3b. Host-side client config
        #
        # Installed here rather than left to the operator: it is derived from the
        # same inventory the guest is built from, so writing it at launch is what
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

          NEW_CONF=$(${sshConfigScript}/bin/permafrost-ssh-config "/run/user/$(id -u "$SUDO_USER")")
          if [ -z "$SKIP_SSH_CONF" ] && [ "$NEW_CONF" != "$(${pkgs.coreutils}/bin/cat "$SSH_CONF" 2>/dev/null)" ]; then
            printf '%s\n' "$NEW_CONF" > "$SSH_CONF"
            ${pkgs.coreutils}/bin/chown "$SUDO_USER:$SUDO_GROUP" "$SSH_CONF"
            chmod 600 "$SSH_CONF"
            echo "Updated $SSH_CONF from the inventory."
          fi
        fi

        case "$COMMAND" in
          status)
            if systemctl is-active --quiet "$UNIT_NAME"; then
              echo "Status: RUNNING"
              echo "IP:     ${spec.ip}"
              echo "CID:    ${toString spec.vsockCid}"
              echo "Runtime: $SOCKET_DIR"
            else
              echo "Status: STOPPED"
            fi
            exit 0
            ;;
          stop)
            echo "Stopping $UNIT_NAME..."
            systemctl stop "$UNIT_NAME"
            exit 0
            ;;
          run|start)
            # Take the lock before the is-active check, otherwise two concurrent
            # launches can both pass the check and then race the preStart wipe of
            # this VM's disk images. The fd is held for the life of the script.
            ${pkgs.coreutils}/bin/mkdir -p "$STATE_DIR"
            exec 9>"$STATE_DIR/.lock"
            if ! ${pkgs.util-linux}/bin/flock -n 9; then
              echo "Error: another launch of ${spec.name} is already in progress."
              exit 1
            fi
            if systemctl is-active --quiet "$UNIT_NAME"; then
              echo "Error: $UNIT_NAME is already running."
              exit 1
            fi
            ;;
          *)
            echo "Usage: $0 {run|start|stop|status}"
            exit 1
            ;;
        esac

        echo "Initializing Pure Sandbox Lifecycle for ${spec.name}..."
        echo "Runtime Directory: $SOCKET_DIR"

        # 3. JIT Networking Setup
        if ! ip link show "$BRIDGE" >/dev/null 2>&1; then
          ip link add name "$BRIDGE" type bridge
          ip addr add "$GATEWAY_IP/24" dev "$BRIDGE"
          ip link set "$BRIDGE" up
        fi

        ${pkgs.procps}/bin/sysctl -w net.ipv4.ip_forward=1 >/dev/null
        EXT_IF=$(ip route | grep default | awk '{print $5}' | head -n1)

        # Idempotent NAT — check-then-add so multiple VMs don't collide.
        # Rules are never removed on cleanup so other VMs keep connectivity.
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

          ${lib.concatMapStringsSep "\n" (
            s:
            let
              tag = "p_" + (builtins.substring 0 30 (builtins.hashString "md5" s.guest));
            in
            ''
              ${pkgs.coreutils}/bin/mkdir -p "$REAL_HOME/${s.host}"
              ${pkgs.virtiofsd}/bin/virtiofsd --socket-path "$SOCKET_DIR/${tag}.sock" --shared-dir "$REAL_HOME/${s.host}" --sandbox namespace &
            ''
          ) allShares}

          # Wait for backend readiness
          echo "Waiting for virtiofsd backends..."
          while [ ! -S "$SOCKET_DIR/ro-store.sock" ]; do ${pkgs.coreutils}/bin/sleep 0.1; done
          while [ ! -S "$SOCKET_DIR/ssh.sock" ]; do ${pkgs.coreutils}/bin/sleep 0.1; done
          # Wait for all other sockets defined in allShares
          ${lib.concatMapStringsSep "\n" (
            s:
            let
              tag = "p_" + (builtins.substring 0 30 (builtins.hashString "md5" s.guest));
            in
            ''while [ ! -S "$SOCKET_DIR/${tag}.sock" ]; do ${pkgs.coreutils}/bin/sleep 0.1; done''
          ) allShares}

          # Final VM Launch
          # All control sockets are placed in SOCKET_DIR: the notify.vsock and
          # nixos.sock are moved here to keep the project root pure.
          ${nixosConfig.config.microvm.declaredRunner}/bin/microvm-run \
            --api-socket "$SOCKET_DIR/nixos.sock" \
            --vsock "cid=${toString spec.vsockCid},socket=$SOCKET_DIR/notify.vsock"
        '

        RUN_ARGS=(
          --unit="$UNIT_NAME"
          --collect
          --service-type=exec
          --property="RuntimeDirectory=$RUNTIME_NAME"
          --property="RuntimeDirectoryPreserve=no"
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
          --property="Environment=AGENT_PUBKEYS=$AGENT_PUBKEYS"
          --description="Permafrost VM: ${spec.name}"
          # Reclaim this VM's ephemeral disk images whenever the unit stops — clean
          # exit, crash, or SIGKILL — in both run and start modes. preStart also
          # wipes on the next boot, so a host power loss leaves at most one stale
          # image set, reclaimed on the next launch or by `nix run .#gc`.
          --property="ExecStopPost=${pkgs.coreutils}/bin/rm -rf $STATE_DIR"
        )

        if [ "$COMMAND" = "run" ]; then
          systemd-run --pty --wait "''${RUN_ARGS[@]}" ${pkgs.bash}/bin/bash -c "$LAUNCH_COMMAND"
        else
          systemd-run "''${RUN_ARGS[@]}" ${pkgs.bash}/bin/bash -c "$LAUNCH_COMMAND"
          echo "${spec.name} started in background (unit: $UNIT_NAME)."
        fi
      '';
    in
    runnerScript;

  # Reclaim ephemeral image directories left behind by agents that are no longer in
  # inventory.nix. ExecStopPost handles the normal case and preStart bounds live
  # agents to one stale image set each, but a deleted agent's directory has nothing
  # left to clean it — that is the only unbounded source of orphans.
  gcScript = pkgs.writeShellScriptBin "permafrost-gc" ''
    set -euo pipefail
    ROOT="/var/lib/permafrost"

    [ -d "$ROOT" ] || { echo "Nothing to collect: $ROOT does not exist."; exit 0; }

    reclaimed=0
    for dir in "$ROOT"/*; do
      [ -d "$dir" ] || continue
      name=$(${pkgs.coreutils}/bin/basename "$dir")
      if systemctl is-active --quiet "microvm-$name"; then
        echo "keep    $name (running)"
        continue
      fi
      size=$(${pkgs.coreutils}/bin/du -sh --apparent-size "$dir" 2>/dev/null | ${pkgs.coreutils}/bin/cut -f1)
      used=$(${pkgs.coreutils}/bin/du -sh "$dir" 2>/dev/null | ${pkgs.coreutils}/bin/cut -f1)
      ${pkgs.coreutils}/bin/rm -rf "$dir"
      echo "reclaim $name (apparent $size, on-disk $used)"
      reclaimed=$((reclaimed + 1))
    done
    echo "Reclaimed $reclaimed directories."
  '';

  # Discovery: which agent owns which address, and what is actually running.
  # machinectl is not usable here — microvm.nix's own runner.nix notes that NSS
  # resolution works for containers but not VMs, so machined would list the VMs
  # without their addresses. IPs are static in inventory.nix, so read them there.
  statusScript = pkgs.writeShellScriptBin "permafrost-status" ''
    set -euo pipefail
    printf '%-13s %-16s %-5s %-18s %s\n' AGENT IP CID TAP STATE
    ${lib.concatMapStringsSep "\n" (spec: ''
      state=$(systemctl is-active "microvm-${spec.name}" 2>/dev/null || true)
      printf '%-13s %-16s %-5s %-18s %s\n' \
        "${spec.name}" "${spec.ip}" "${toString spec.vsockCid}" \
        "microvm-${spec.tapId}" "$state"
    '') (lib.attrValues vms)}
  '';

  # The host-side ssh_config for reaching guests, derived from the inventory the
  # guests are built from.
  #
  # The catch-all block needs no maintenance, because everything in it is
  # structural rather than per-agent: the 192.168.33.0/24 subnet, `agent` as the
  # only login user, host keys regenerated on every boot, and one forwarding
  # socket. Adding an agent changes only the aliases below it, and those are
  # generated from the same source, so neither can drift from the inventory.
  #
  # Takes the runtime directory holding the agent socket, so the path is
  # resolved for whoever will actually run ssh rather than assuming a uid.
  # Runners call this with the launching user's own directory and install the
  # result; running it by hand prints the same thing for the current user.
  sshConfigScript = pkgs.writeShellScriptBin "permafrost-ssh-config" ''
    RUNTIME_DIR="''${1:-/run/user/$(id -u)}"

    ${pkgs.gnused}/bin/sed "s|@SOCK@|$RUNTIME_DIR/permafrost-agent.sock|" <<'EOF'
    # Managed by nix-permafrost. Rewritten from modules/inventory.nix every time
    # an agent is launched, so edits here are lost — change the inventory instead.
    #
    # The socket below is the permafrost agent, carrying the agentic key alone.
    # Never point it at the personal agent: every guest would gain the use of
    # your personal key for the life of the connection.

    Host 192.168.33.* permafrost-*
      User agent
      ForwardAgent @SOCK@

      # Guests are rebuilt from scratch on every boot and present a new host key
      # each time, so a persistent known_hosts entry refuses the second launch.
      # Scoped to these guests only — the global default still applies elsewhere.
      StrictHostKeyChecking no
      UserKnownHostsFile /dev/null

      ServerAliveInterval 150
      ServerAliveCountMax 2

    # Convenience aliases. The subnet block above already covers these addresses,
    # so a stale alias costs nothing beyond the name.
    ${lib.concatMapStringsSep "\n" (spec: ''
      Host permafrost-${spec.name}
        Hostname ${spec.ip}
    '') (lib.attrValues vms)}
    EOF
  '';

in
{
  status = statusScript;
  gc = gcScript;
  ssh-config = sshConfigScript;

  claude = mkRunner vms.claude;
  opencode = mkRunner vms.opencode;
  pi = mkRunner vms.pi;
  bv = mkRunner vms.bv;
  antigravity = mkRunner vms.antigravity;
  crush = mkRunner vms.crush;
  default = mkRunner vms.claude;
}
