{
  # tmux is configured here rather than at the system level so that stylix,
  # whose tmux target is Home Manager only, owns its colours. The binary is in
  # environment.systemPackages (guest/base.nix) as well, for root.
  #
  # The bindings are not written out here: they come from _lib/keymap.nix, the
  # same source guest/home/herdr.nix renders herdr's `[keys]` table from, so the
  # two multiplexers cannot drift apart.
  flake.modules.homeManager.agent-tmux =
    { pkgs, lib, ... }:
    let
      keymap = import ../../_lib/keymap.nix { inherit lib; };
    in
    {
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
        shortcut = keymap.prefix.tmux;

        extraConfig = ''
          # tmux starts a login shell by default, which can reset PATH.
          set -g default-command "${pkgs.bash}/bin/bash"

          set -g extended-keys on
          set -g extended-keys-format csi-u

          # Status layout only — colours come from stylix.targets.tmux
          set -g status-left "#[bold] #S #[default]| "
          set -g status-right " %Y-%m-%d %H:%M:%S "
          set -g window-status-format " #I:#W "
          set -g window-status-current-format " #I:#W "

          ${keymap.renderTmux keymap.multiplexer}

          unbind '"'
          unbind %

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
    };
}
