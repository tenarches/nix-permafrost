{ inputs, config, ... }:
{
  # The guest as a declarative microvm on the host, started by
  # microvm@permafrost.service rather than by `nix run`.
  #
  # It is built from exactly the same flake.lib.guestModules the runner path uses,
  # with launch-fleet swapped in for launch-runner, so a guest is identical
  # however it was started.
  #
  # flake.modules.nixos.nixpkgs is deliberately *not* in that list, unlike the
  # runner path. microvm.nix hands a fleet guest the host's own pkgs instance, and
  # a configuration given an external instance may not also set nixpkgs.config —
  # it fails the assertion in nixpkgs/modules/misc/nixpkgs.nix. The overlays and
  # allowUnfree the guest needs are already on that instance, applied by
  # host/configuration.nix.
  flake.modules.nixos.host-fleet = {
    microvm.vms.permafrost = {
      autostart = false;
      specialArgs = { inherit inputs; };
      config.imports = config.flake.lib.guestModules ++ [
        config.flake.modules.nixos.launch-fleet
      ];
    };
  };
}
