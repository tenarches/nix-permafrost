{ inputs, config, ... }:
let
  inherit (config) flake;
in
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
  flake.modules.nixos.host-fleet =
    { config, lib, ... }:
    {
      options.permafrost.host.autostart = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Start the guest when the host boots (`microvm.vms.permafrost.autostart`).

          The guest of this launch path has no `launch` or `ssh_keys` share,
          which only the runner can fill (see launch-fleet.nix): no tailnet
          key, no dsh secret and no key harvested from an agent. A host that
          starts the guest with the runner (`sudo nix run .#permafrost start`)
          leaves this off.
        '';
      };

      config.microvm.vms.permafrost = {
        inherit (config.permafrost.host) autostart;
        specialArgs = { inherit inputs; };
        config.imports = flake.lib.guestModules ++ [
          flake.modules.nixos.launch-fleet
        ];
      };
    };
}
