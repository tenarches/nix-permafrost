{ inputs, pkgs, ... }:

{
  # Shared Agent Environment: Standardized tools and configurations
  # Mirrors the patterns of high-quality agent environments

  home-manager.users.agent = {
    home = {
      stateVersion = "25.11";
      sessionPath = [ "$HOME/.local/bin" ];
      packages = [
        inputs.devenv.packages.${pkgs.stdenv.hostPlatform.system}.devenv
        pkgs.uv
        pkgs.nodejs
      ];
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
