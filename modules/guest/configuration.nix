{ inputs, config, ... }:
{
  # The guest as the runner launches it. Exposed as a real nixosConfiguration
  # rather than built inline inside the runner package, so `nix flake check`
  # evaluates it, `nix build .#nixosConfigurations.permafrost...` works, and the
  # runner script can read the merged share list out of it instead of being
  # handed a copy.
  flake.nixosConfigurations.permafrost = inputs.nixpkgs.lib.nixosSystem {
    specialArgs = { inherit inputs; };
    modules = config.flake.lib.guestModules ++ [
      config.flake.modules.nixos.nixpkgs
      config.flake.modules.nixos.launch-runner
      # The only system string in the guest's build. systems = [ "x86_64-linux" ]
      # in modules/flake/systems.nix, and a nixosConfiguration has to pick one.
      { nixpkgs.hostPlatform.system = "x86_64-linux"; }
    ];
  };
}
