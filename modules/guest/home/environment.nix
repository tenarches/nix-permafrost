{
  # The shared agent environment: the tooling every harness expects to find,
  # independent of which harness it is.
  flake.modules.homeManager.agent-environment =
    { inputs, pkgs, ... }:
    {
      home = {
        stateVersion = "26.05";
        sessionPath = [
          "$HOME/bin"
          "$HOME/.local/bin"
        ];
        packages = [
          inputs.devenv.packages.${pkgs.stdenv.hostPlatform.system}.devenv
          pkgs.uv
          pkgs.nodejs
          # The linters of this repository's own pre-commit hooks
          # (flake/pre-commit.nix). Agents ran each through `nix run` when absent.
          pkgs.nixfmt
          pkgs.statix
          pkgs.deadnix
        ];
      };

      # stylix.autoEnable is off in guest/theme.nix, so every target is opt-in.
      # These two are the only ones that reach a headless terminal guest.
      stylix.targets = {
        tmux.enable = true;
        nixvim.enable = true;
      };

      programs.direnv = {
        enable = true;
        nix-direnv.enable = true;
      };
    };
}
