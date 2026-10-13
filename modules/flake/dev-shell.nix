{ inputs, ... }:
{
  perSystem =
    {
      config,
      pkgs,
      system,
      ...
    }:
    {
      devShells.default = pkgs.mkShell {
        shellHook = config.pre-commit.installationScript;
        packages = [
          # Same Nix as the guest (modules/guest/base.nix), not pkgs.nix.
          pkgs.nixVersions.latest
          inputs.devenv.packages.${system}.devenv
          pkgs.sops
          pkgs.age
          pkgs.virtiofsd
          config.pre-commit.settings.package
        ];
      };
    };
}
