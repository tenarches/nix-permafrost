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
          inputs.devenv.packages.${system}.devenv
          pkgs.sops
          pkgs.age
          pkgs.virtiofsd
          config.pre-commit.settings.package
        ];
      };
    };
}
