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

  # Enable IP forwarding for NAT
  boot.kernel.sysctl."net.ipv4.ip_forward" = 1;

  # Required packages on the host
  environment.systemPackages = with pkgs; [
    virtiofsd
    bridge-utils
  ];
}
