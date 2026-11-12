{
  # The declarative launch path: microvm.vms.permafrost on the host, started by
  # microvm@permafrost.service.
  #
  # The host module runs virtiofsd itself, so shares name real host paths and no
  # sockets. permafrost.gui is deliberately ignored here — microvm.graphics on
  # cloud-hypervisor needs a host-side `crosvm device gpu` pointed at a live
  # compositor via $XDG_RUNTIME_DIR/$WAYLAND_DISPLAY, and a system unit has
  # neither. GUI is runner-only.
  #
  # There is no ssh_keys share either: nothing here harvests keys from an agent,
  # so a fleet-started guest is reachable only over the serial console unless
  # something else puts a key in ~agent/.ssh/authorized_keys.
  flake.modules.nixos.launch-fleet =
    { config, lib, ... }:
    let
      shareLib = import ../_lib/shares.nix;
      slotLib = import ../_lib/slots.nix;
      cfg = config.permafrost;
    in
    {
      microvm.shares = [
        {
          tag = "ro-store";
          proto = "virtiofs";
          source = "/nix/store";
          mountPoint = "/nix/.ro-store";
        }
      ]
      ++ lib.optional cfg.slots.workspaces.enable {
        # The workspaces of the factory slots. The host creates the directories
        # (host/workspaces.nix). posixAcl is off because virtiofsd refuses it
        # together with the id map, and microvm.nix asserts the same.
        tag = slotLib.shareTag;
        proto = "virtiofs";
        source = cfg.slots.workspaces.hostPath;
        mountPoint = slotLib.shareMount;
        posixAcl = false;
        extraArgs = slotLib.virtiofsdArgs cfg.slots;
      }
      ++ map (s: {
        tag = shareLib.tag s;
        proto = "virtiofs";
        source = "/mnt/persist/${s.guest}";
        mountPoint = "/mnt/persist/${s.guest}";
      }) cfg.shares;
    };
}
