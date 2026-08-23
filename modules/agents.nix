{
  inputs,
  pkgs,
  lib,
  ...
}:

let
  vms = import ./inventory.nix {
    inherit inputs pkgs;
  };

  mkAgentVm = spec: {
    autostart = false;
    specialArgs = { inherit inputs; };
    config = {
      # spec.extraModules is the escape hatch for a guest that needs NixOS
      # config of its own rather than another spec field. homeFiles can only
      # produce read-only store symlinks and env can only set variables, so a
      # harness wanting an activation script, a firewall port or a systemd unit
      # has nowhere else to put it. Reached from both launch paths, so a guest
      # behaves the same under `nix run` as it does in the fleet.
      imports = [ ./agent-base.nix ] ++ (spec.extraModules or [ ]);

      nixpkgs.overlays = spec.overlays or [ ];

      microvm = {
        # No workspace share: each guest gets a private ephemeral workspace on its
        # own home volume (see agent-base.nix), so no host directory is shared.
        #
        # spec.gui is deliberately ignored here. microvm.graphics on
        # cloud-hypervisor needs a host-side `crosvm device gpu` pointed at a
        # live compositor via $XDG_RUNTIME_DIR/$WAYLAND_DISPLAY, and the host
        # module's microvm@<name>.service is a system unit with neither. GUI
        # guests are runner-only: `nix run .#antigravity`.
        shares = map (s: {
          source = "/mnt/persist/${s.guest}";
          mountPoint = "/mnt/persist/${s.guest}";
          # Hash the guest path to stay within the 36-char virtiofs tag limit
          tag = "p_" + (builtins.substring 0 30 (builtins.hashString "md5" s.guest));
          proto = "virtiofs";
        }) (spec.persistentShares or [ ]);

        vsock.cid = spec.vsockCid;
        interfaces = [
          {
            type = "tap";
            id = "vm-" + spec.tapId;
            inherit (spec) mac;
          }
        ];
      };

      environment.variables = spec.env or { };

      # microvm.credentialFiles = spec.credentials or {};

      networking = {
        hostName = spec.name;
        interfaces.eth0.ipv4.addresses = [
          {
            address = spec.ip;
            prefixLength = 24;
          }
        ];
        defaultGateway = {
          address = "192.168.33.1";
          interface = "eth0";
        };
      };

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
    };
  };
in
{
  microvm.vms = lib.mapAttrs (_: mkAgentVm) vms;
}
