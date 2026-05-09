{ pkgs, ... }:

{
  # Shared Agent Environment: Standardized tools and configurations
  # Mirrors the patterns of high-quality agent environments

  home-manager.users.agent = {
    home.stateVersion = "25.11";

    # MCP Servers and tools
    home.packages = with pkgs; [
      uv
      nodejs
    ];

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
