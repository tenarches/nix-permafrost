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
        # Deduplicate identical store files via hard links. This store is also
        # the guest's read-only lower layer; dedup here would have absorbed
        # nearly all 28GB of the store outage with zero behaviour change for
        # anything reading the store. (The guest cannot set this itself —
        # microvm.nix asserts it does not work with writableStoreOverlay.)
        auto-optimise-store = true;
        # When free space drops below min-free during a build, the daemon
        # garbage-collects until max-free bytes are free, so the store stops
        # short of 100%. max-free is bounded because the default (infinite)
        # would collect every unrooted path on the first trigger.
        min-free = 5368709120; # 5 GiB
        max-free = 21474836480; # 20 GiB
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
