{ inputs, pkgs, ... }:

{
  # Shared Agent Environment: Standardized tools and configurations
  # Mirrors the patterns of high-quality agent environments

  home-manager.users.agent = {
    home = {
      stateVersion = "26.05";
      sessionPath = [ "$HOME/.local/bin" ];
      packages = [
        inputs.devenv.packages.${pkgs.stdenv.hostPlatform.system}.devenv
        pkgs.uv
        pkgs.nodejs
      ];
    };

    # stylix.autoEnable is off in theme.nix, so every target is opt-in. These
    # two are the only ones that reach a headless terminal guest.
    stylix.targets = {
      tmux.enable = true;
      nixvim.enable = true;
    };

    programs.direnv = {
      enable = true;
      nix-direnv.enable = true;
    };

    programs.tmux = {
      enable = true;
      shortcut = "a";
      terminal = "screen-256color";
      # Collaborative/Agentic persistence settings
      extraConfig = ''
        set -g mouse on
        set -g history-limit 50000
      '';
    };

    # Note: Nixvim configuration would typically go here.
    # For now, we ensure the infrastructure exists.
  };
}
