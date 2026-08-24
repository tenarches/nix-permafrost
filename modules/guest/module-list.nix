{ config, lib, ... }:
{
  # The guest's module list, resolved by naming convention rather than kept by
  # hand: `guest-*` is what the guest always is, `harness-*` is an agent it
  # carries. Adding either is adding one file.
  #
  # Both launch paths consume this — guest/configuration.nix for `nix run` and
  # host/fleet.nix for microvm.vms — which is what keeps a guest identical
  # however it was started. The launch modules themselves are deliberately
  # outside the convention: exactly one of them is added per path.
  #
  # This lives under flake.lib rather than being computed in the two consumers,
  # so neither of them has to read flake.modules.nixos while contributing to it.
  flake.lib.guestModules = lib.attrValues (
    lib.filterAttrs (
      name: _: lib.hasPrefix "guest-" name || lib.hasPrefix "harness-" name
    ) config.flake.modules.nixos
  );
}
