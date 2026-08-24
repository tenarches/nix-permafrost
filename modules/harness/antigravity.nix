{
  # No shares: this harness keeps nothing worth carrying across a boot.
  flake.modules.nixos.harness-antigravity =
    { pkgs, ... }:
    {
      environment.systemPackages = [ pkgs.antigravity-cli ];
    };
}
