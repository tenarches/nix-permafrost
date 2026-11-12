{ config, ... }:
{
  # The VM checks of the guest modules. Each one boots plain NixOS nodes with a
  # few of the modules under test, never the guest itself (no microvm, no
  # volumes): what a check proves is the behaviour of those modules. The test
  # files are under modules/_checks, whose underscore keeps import-tree from
  # loading them as flake-parts modules (the same rule as _pkgs and _lib).
  perSystem =
    { pkgs, ... }:
    {
      checks.vm-slots = import ../_checks/slots.nix {
        inherit pkgs;
        nixosModules = config.flake.modules.nixos;
      };
    };
}
