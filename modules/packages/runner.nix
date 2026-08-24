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
      # per agent. Per-agent names are not kept as aliases: each would boot the
      # same VM under a label that distinguishes nothing.
      packages = {
        permafrost = runner;
        default = runner;
      };
    };
}
