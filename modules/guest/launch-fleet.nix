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
    { config, ... }:
    let
      shareLib = import ../_lib/shares.nix;
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
      ++ map (s: {
        tag = shareLib.tag s;
        proto = "virtiofs";
        source = "/mnt/persist/${s.guest}";
        mountPoint = "/mnt/persist/${s.guest}";
      }) cfg.shares;
    };
}
