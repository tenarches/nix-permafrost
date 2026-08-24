{
  flake.modules.nixos.host-bridge =
    {
      pkgs,
      ...
    }:

    {
      systemd.network = {
        netdevs."10-microbr".netdevConfig = {
          Kind = "bridge";
          Name = "microbr";
        };

        networks."10-microbr" = {
          matchConfig.Name = "microbr";
          addresses = [ { Address = "192.168.33.1/24"; } ];
          networkConfig.ConfigureWithoutCarrier = true;
        };

        # All tap interfaces microvm.nix creates get bridged here
        networks."11-microvm-tap" = {
          matchConfig.Name = "microvm*";
          networkConfig.Bridge = "microbr";
        };
      };

      # NAT outbound through the primary uplink
      # Note: externalInterface should be adjusted to the actual host interface
      networking.nat = {
        enable = true;
        internalInterfaces = [ "microbr" ];
        externalInterface = "wlp4s0"; # Default for laptop
      };

      # Disable nested virtualization
      boot.extraModprobeConfig = "options kvm-amd nested=0";

      # Enable IP forwarding for NAT
      boot.kernel.sysctl."net.ipv4.ip_forward" = 1;

      # Privilege escalation mitigation
      services.udev.extraRules = ''
        KERNEL=="kvm", GROUP="kvm", MODE="0660", OPTIONS+="static_node=kvm"
      '';

      # Required packages on the host
      environment.systemPackages = with pkgs; [
        virtiofsd
        bridge-utils
        # Fallback display transport for GUI guests when the virtio-gpu proxy
        # misbehaves: `waypipe --no-gpu ssh agent@192.168.33.10 <app>`.
        waypipe
      ];

      nix.settings = {
        experimental-features = [
          "nix-command"
          "flakes"
        ];
        trusted-users = [
          "root"
          "agent"
        ];
        substituters = [
          "https://cache.nixos.org/"
          "https://devenv.cachix.org"
        ];
        trusted-public-keys = [
          "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
          "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw="
        ];
      };
    };
}
