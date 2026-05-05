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
      imports = [ ./agent-base.nix ];

      microvm = {
        shares = [
          {
            source = spec.workspacePath;
            mountPoint = "/workspace";
            tag = "workspace";
            proto = "virtiofs";
          }
        ]
        ++ (lib.optionals (spec.gui or false) [
          {
            source = "/run/user/1000/wayland-0";
            mountPoint = "/run/user/1000/wayland-0";
            tag = "wayland";
            proto = "virtiofs";
          }
        ]);

        vsock.cid = spec.vsockCid;
        interfaces = [
          {
            type = "tap";
            id = "vm-" + spec.tapId;
            inherit (spec) mac;
          }
        ];
      };

      environment.variables = lib.optionalAttrs (spec.gui or false) {
        WAYLAND_DISPLAY = "wayland-0";
        XDG_RUNTIME_DIR = "/run/user/1000";
        NIXOS_OZONE_WL = "1";
        LIBGL_ALWAYS_SOFTWARE = "1";
        WLR_RENDERER_ALLOW_SOFTWARE = "1";
      };

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
    };
  };
in
{
  microvm.vms = lib.mapAttrs (_: mkAgentVm) vms;
}
