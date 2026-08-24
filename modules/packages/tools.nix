{ config, ... }:
{
  perSystem =
    { pkgs, ... }:
    {
      packages = import ../_pkgs/tools.nix {
        inherit pkgs;
        nixos = config.flake.nixosConfigurations.permafrost;
      };
    };
}
