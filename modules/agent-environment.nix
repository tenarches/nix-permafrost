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
      shell = "${pkgs.bash}/bin/bash";
      terminal = "tmux-256color";
      historyLimit = 100000;
      keyMode = "vi";
      mouse = true;
      baseIndex = 1;
      escapeTime = 0; # Fix for Neovim lag
      # Approachable screen-like binding
      shortcut = "a";

      extraConfig = ''
        # tmux starts a login shell by default, which can reset PATH.
        set -g default-command "${pkgs.bash}/bin/bash"

        # Retained from the system-level tmux config this replaced
        set -g extended-keys on
        set -g extended-keys-format csi-u

        # Status layout only — colours come from stylix.targets.tmux
        set -g status-left "#[bold] #S #[default]| "
        set -g status-right " %Y-%m-%d %H:%M:%S "
        set -g window-status-format " #I:#W "
        set -g window-status-current-format " #I:#W "

        # Easy splits
        bind | split-window -h -c "#{pane_current_path}"
        bind - split-window -v -c "#{pane_current_path}"
        unbind '"'
        unbind %

        # Vim-style pane selection
        bind h select-pane -L
        bind j select-pane -D
        bind k select-pane -U
        bind l select-pane -R

        # Shift-arrow to switch windows
        bind -n S-Left  previous-window
        bind -n S-Right next-window

        # Right-click to paste from the tmux buffer
        bind-key -n MouseDown3Pane paste-buffer

        # Copies leave tmux over OSC 52, which also works across SSH.
        # terminal-features matches the outer terminal's TERM, which kitty and
        # ghostty both set to xterm-256color.
        set -g set-clipboard on
        set -as terminal-features ',xterm-256color:clipboard'

        # Wheel scroll enters copy-mode, but passes through to full-screen
        # mouse-aware programs (vim, less, htop). -e exits copy-mode on
        # reaching the bottom.
        bind -n WheelUpPane if -Ft= '#{mouse_any_flag}' 'send -M' \
          "if -Ft= '#{pane_in_mode}' 'send -M' 'copy-mode -e'"

        # Vi-style selection in copy-mode
        bind -T copy-mode-vi v send -X begin-selection
        bind -T copy-mode-vi y send -X copy-pipe-and-cancel
        bind -T copy-mode-vi MouseDragEnd1Pane send -X copy-pipe-no-clear
      '';
    };

    # Note: Nixvim configuration would typically go here.
    # For now, we ensure the infrastructure exists.
  };
}
