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

  # wayland-1 is wayland-proxy-virtwl's default socket name. These land in
  # /etc/set-environment, which login shells source — so an interactive ssh
  # session is already pointed at the proxy.
  environment.variables = {
    WAYLAND_DISPLAY = "wayland-1";
    DISPLAY = ":0";
    XDG_SESSION_TYPE = "wayland"; # Electron reads this
    QT_QPA_PLATFORM = "wayland";
    GDK_BACKEND = "wayland";
    SDL_VIDEODRIVER = "wayland";
    CLUTTER_BACKEND = "wayland";
    NIXOS_OZONE_WL = "1";
    # No native GPU is passed through; rendering is llvmpipe and the proxy only
    # moves the resulting buffers.
    LIBGL_ALWAYS_SOFTWARE = "1";
    WLR_RENDERER_ALLOW_SOFTWARE = "1";
  };

  environment.systemPackages = with pkgs; [
    xdg-utils
    # Fallback transport: from a host terminal, `waypipe ssh agent@<ip> <app>`.
    waypipe
  ];
}
