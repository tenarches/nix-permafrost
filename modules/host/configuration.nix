{ inputs, config, ... }:
{
  # The host that runs the guest. Named permafrost-host because the guest itself
  # is `permafrost` — one VM carrying every harness — and two machines on the
  # same bridge cannot share a hostname.
  #
  # This is a thin configuration: it exists to hold the bridge, the secrets and
  # the fleet unit, and to give `nix flake check` something to evaluate them
  # against. It is not the workstation configuration.
  flake.nixosConfigurations.permafrost-host = inputs.nixpkgs.lib.nixosSystem {
    specialArgs = { inherit inputs; };
    modules = [
      config.flake.modules.nixos.nixpkgs
      config.flake.modules.nixos.host-bridge
      config.flake.modules.nixos.host-secrets
      config.flake.modules.nixos.host-fleet

      inputs.microvm.nixosModules.host

      {
        # systems = [ "x86_64-linux" ] in modules/flake/systems.nix, and a
        # nixosConfiguration has to pick one.
        nixpkgs.hostPlatform.system = "x86_64-linux";

        networking.hostName = "permafrost-host";
        system.stateVersion = "26.05";

        # Minimal config to pass nix flake check
        fileSystems."/" = {
          device = "tmpfs";
          fsType = "tmpfs";
        };
        boot.loader.grub.enable = false;
        boot.loader.generic-extlinux-compatible.enable = true;

        users.users.agent = {
          isNormalUser = true;
          extraGroups = [
            "wheel"
            "networkmanager"
            "microvm"
          ];
        };
      }
    ];
  };
}
