{ config, ... }:
{
  perSystem =
    { pkgs, ... }:
    let
      nixos = config.flake.nixosConfigurations.permafrost;
      tools = import ../_pkgs/tools.nix { inherit pkgs nixos; };
      runner = import ../_pkgs/runner.nix {
        inherit pkgs nixos;
        sshConfig = tools.ssh-config;
      };
    in
    {
      # One guest carrying every harness, so there is one runner rather than one
      # per agent. The old per-agent names are gone rather than aliased: each
      # would have booted the same VM under a name that no longer distinguishes
      # anything.
      packages = {
        permafrost = runner;
        default = runner;
      };
    };
}
