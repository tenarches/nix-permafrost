{
  pkgs,
  lib,
  config,
  ...
}:

# Guest-side half of microvm.nix's GUI support. Gated on the upstream option
# rather than on a `spec.gui` flag so it self-activates wherever the host side
# turns graphics on (currently only the JIT runners in runners.nix — see the
# note in modules/agents.nix about why the declarative host path cannot).
#
# How a window gets to the host compositor:
#
#   guest app ──▶ $XDG_RUNTIME_DIR/wayland-1 ──▶ wayland-proxy-virtwl
#                                                    │ virtio-gpu (cross-domain)
#                                                    ▼
#   host `crosvm device gpu` ──▶ host compositor's $WAYLAND_DISPLAY
#
# The host-side crosvm vhost-user GPU device is started by microvm.nix's own
# cloud-hypervisor preStart; nothing here has to arrange it.

lib.mkIf config.microvm.graphics.enable {
  # virtio_gpu gives the guest /dev/dri/renderD128, which the proxy allocates
  # its shared buffers from. boot.kernelModules for it come from microvm.nix's
  # own graphics module.
  hardware.graphics.enable = true;

  # A *user* service, so its socket lands in /run/user/1000 and is reachable by
  # anything the agent runs later — including a shell opened over ssh long after
  # boot. pam_systemd starts user@1000.service on ssh login, which pulls this in.
  systemd.user.services.wayland-proxy = {
    description = "Wayland proxy (virtio-gpu) onto the host compositor";
    wantedBy = [ "default.target" ];
    serviceConfig = {
      # --x-display=0 additionally serves X11 clients through Xwayland at
      # DISPLAY=:0, so sshd needs no X11Forwarding.
      ExecStart = lib.concatStringsSep " " [
        (lib.getExe pkgs.wayland-proxy-virtwl)
        "--virtio-gpu"
        "--x-display=0"
        "--xwayland-binary=${pkgs.xwayland}/bin/Xwayland"
      ];
      Restart = "on-failure";
      RestartSec = 5;
    };
  };

  # Only the two variables that name the proxy's own sockets belong here.
  # wayland-1 is wayland-proxy-virtwl's default socket name, and :0 comes from
  # --x-display=0 above. Both land in /etc/set-environment, which login shells
  # source, so an interactive ssh session is already pointed at the proxy.
  #
  # Everything else — the toolkit hints — lives in agent-base.nix, because
  # waypipe needs them too and it works without this module. Setting
  # WAYLAND_DISPLAY there would be actively wrong: waypipe exports its own for
  # the process it launches, and a stale global pointing at a nonexistent
  # wayland-1 would break it.
  environment.variables = {
    WAYLAND_DISPLAY = "wayland-1";
    DISPLAY = ":0";
  };

}
