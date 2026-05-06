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

  mkRunner =
    spec:
    let
      globalShares = [
        {
          host = ".agents";
          guest = ".agents";
        }
        {
          host = "workspace";
          guest = "workspace";
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
                hostPlatform = system;
                config.allowUnfree = true;
              };
              microvm = {
                vsock.cid = spec.vsockCid;
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
                    tag = "persist_" + (lib.replaceStrings [ "." "/" ] [ "_" "_" ] s.guest);
                    proto = "virtiofs";
                    socket =
                      "/run/microvm-${spec.name}/persist_"
                      + (lib.replaceStrings [ "." "/" ] [ "_" "_" ] s.guest)
                      + ".sock";
                  }) allShares)
                  ++ (lib.optionals (spec.gui or false) [
                    {
                      source = "/run/user/1000";
                      mountPoint = "/run/user/1000";
                      tag = "wayland";
                      proto = "virtiofs";
                      socket = "/run/microvm-${spec.name}/wayland.sock";
                    }
                  ])
                );
              };

              environment.variables =
                (lib.optionalAttrs (spec.gui or false) {
                  WAYLAND_DISPLAY = "@@HOST_WAYLAND_DISPLAY@@"; # Replaced by runner script
                  XDG_RUNTIME_DIR = "/run/user/1000";
                  NIXOS_OZONE_WL = "1";
                  LIBGL_ALWAYS_SOFTWARE = "1";
                  WLR_RENDERER_ALLOW_SOFTWARE = "1";
                })
                // (spec.env or { });

              # Match any virtio network interface
              systemd.network.networks."10-lan" = {
                matchConfig.Name = "en*";
                address = [ "${spec.ip}/24" ];
                gateway = [ "192.168.33.1" ];
                dns = [
                  "10.0.7.15"
                  "10.0.7.16"
                  "1.1.1.1"
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
                ++ (lib.concatMap (
                  s:
                  lib.optional (
                    s ? guestLink
                  ) "L+ /home/agent/${s.guestLink} - - - - /mnt/persist/${s.guest}/${builtins.baseNameOf s.guestLink}"
                ) (spec.persistentShares or [ ]));
            }
          )
        ];
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

        # 2. Lifecycle & Path Configuration
        # We use Systemd RuntimeDirectory for "pure" automatic cleanup of all sockets/pids
        RUNTIME_NAME="microvm-${spec.name}"
        SOCKET_DIR="/run/$RUNTIME_NAME"
        UNIT_NAME="microvm-${spec.name}"
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
          # Try to find the user's agent if they forgot sudo -E
          USER_ID=$(id -u "$SUDO_USER")
          PROBED_SOCK=$(find "/run/user/$USER_ID" -name "ssh" -o -name "agent.*" 2>/dev/null | head -n1)
          if [ -n "$PROBED_SOCK" ]; then
            export SSH_AUTH_SOCK="$PROBED_SOCK"
            echo "Auto-detected SSH agent for $SUDO_USER at $SSH_AUTH_SOCK"
          fi
        fi

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

        # Capture for use inside cleanup — EXT_IF may be empty if no default route exists
        EXT_IF_AT_LAUNCH="$EXT_IF"

        cleanup() {
          echo "Permafrost: cleaning up ${spec.name}..."

          if [ -n "$EXT_IF_AT_LAUNCH" ]; then
            ${pkgs.iptables}/bin/iptables -t nat -D POSTROUTING \
              -s 192.168.33.0/24 -o "$EXT_IF_AT_LAUNCH" -j MASQUERADE 2>/dev/null || true
            ${pkgs.iptables}/bin/iptables -D FORWARD \
              -i "$BRIDGE" -j ACCEPT 2>/dev/null || true
            ${pkgs.iptables}/bin/iptables -D FORWARD \
              -o "$BRIDGE" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
          fi

          # Remove bridge only if no tap interfaces remain attached
          if ip link show "$BRIDGE" >/dev/null 2>&1; then
            ATTACHED=$(ls /sys/class/net/"$BRIDGE"/brif 2>/dev/null | wc -l)
            if [ "$ATTACHED" -eq 0 ]; then
              ip link set "$BRIDGE" down 2>/dev/null || true
              ip link del "$BRIDGE" 2>/dev/null || true
              echo "Permafrost: bridge $BRIDGE removed."
            else
              echo "Permafrost: bridge $BRIDGE still has $ATTACHED attached interface(s); leaving in place."
            fi
          fi

          echo "Permafrost: cleanup complete for ${spec.name}."
        }

        if [ "$COMMAND" = "run" ]; then
          trap cleanup EXIT INT TERM
        fi

        if [ -n "$EXT_IF" ]; then
          ${pkgs.iptables}/bin/iptables -t nat -C POSTROUTING -s 192.168.33.0/24 -o "$EXT_IF" -j MASQUERADE 2>/dev/null || \
            ${pkgs.iptables}/bin/iptables -t nat -A POSTROUTING -s 192.168.33.0/24 -o "$EXT_IF" -j MASQUERADE
          ${pkgs.iptables}/bin/iptables -C FORWARD -i "$BRIDGE" -j ACCEPT 2>/dev/null || \
            ${pkgs.iptables}/bin/iptables -A FORWARD -i "$BRIDGE" -j ACCEPT
          ${pkgs.iptables}/bin/iptables -C FORWARD -o "$BRIDGE" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
            ${pkgs.iptables}/bin/iptables -A FORWARD -o "$BRIDGE" -m state --state RELATED,ESTABLISHED -j ACCEPT
        fi

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
          
          ${lib.optionalString (spec.gui or false) ''
            ${pkgs.virtiofsd}/bin/virtiofsd --socket-path "'$SOCKET_DIR'/wayland.sock" --shared-dir "$HOST_XDG_RUNTIME_DIR" --sandbox namespace &
          ''}

          ${lib.concatMapStringsSep "\n" (
            s:
            let
              tag = "persist_" + (lib.replaceStrings [ "." "/" ] [ "_" "_" ] s.guest);
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
              tag = "persist_" + (lib.replaceStrings [ "." "/" ] [ "_" "_" ] s.guest);
            in
            ''while [ ! -S "$SOCKET_DIR/${tag}.sock" ]; do ${pkgs.coreutils}/bin/sleep 0.1; done''
          ) allShares}

          # Final VM Launch
          # We patch the cmdline for Wayland and ensure all control sockets are in SOCKET_DIR
          # The notify.vsock and nixos.sock are moved here to keep the project root pure.
          ${nixosConfig.config.microvm.declaredRunner}/bin/microvm-run \
            --cmdline "wayland_display=$HOST_WAYLAND_DISPLAY " \
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
          --property="Environment=SOCKET_DIR=$SOCKET_DIR"
          --property="Environment=RUNTIME_NAME=$RUNTIME_NAME"
          --property="Environment=SSH_KEYS_DIR=$SSH_KEYS_DIR"
          --property="Environment=AGENT_PUBKEYS=$AGENT_PUBKEYS"
          --description="Permafrost VM: ${spec.name}"
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

in
{
  claude = mkRunner vms.claude;
  gemini = mkRunner vms.gemini;
  opencode = mkRunner vms.opencode;
  pi = mkRunner vms.pi;
  bv = mkRunner vms.bv;
  antigravity = mkRunner vms.antigravity;
  crush = mkRunner vms.crush;
  default = mkRunner vms.claude;
}
