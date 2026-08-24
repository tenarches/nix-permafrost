{
  # herdr — a terminal multiplexer that treats coding agents as first-class
  # panes: it detects which agent is running where, tracks whether each one is
  # working or waiting, and can resume a pane back into its native conversation.
  #
  # Bindings come from _lib/keymap.nix, the same source guest/home/tmux.nix
  # renders from, so the leader key, splits, pane navigation and window
  # switching behave identically in both. herdr allows exactly one binding per
  # action, so where tmux binds two chords (prefix+p/n and Shift-arrow for
  # window nav) herdr gets the no-prefix chord.
  #
  # theme.name = "terminal" makes herdr draw its pane content from the outer
  # terminal's ANSI palette, which stylix has already themed. Only the sidebar
  # chrome needs telling, and those tokens are pinned to the same base16 scheme
  # guest/theme.nix sets — so herdr matches tmux and nixvim without stylix
  # needing a herdr target.
  #
  # Nothing under ~/.herdr is a permafrost.share. Worktrees and session state
  # die with the guest, like the rest of its workspace.
  flake.modules.homeManager.agent-herdr =
    {
      pkgs,
      lib,
      config,
      ...
    }:

    let
      keymap = import ../../_lib/keymap.nix { inherit lib; };
      c = config.lib.stylix.colors.withHashtag;

      settings = {
        onboarding = false;

        theme = {
          name = "terminal";
          custom = {
            accent = c.base0D;
            panel_bg = c.base00;
            surface0 = c.base01;
            surface1 = c.base02;
            surface_dim = c.base01;
            overlay0 = c.base03;
            overlay1 = c.base04;
            text = c.base05;
            subtext0 = c.base04;
            red = c.base08;
            peach = c.base09;
            yellow = c.base0A;
            green = c.base0B;
            teal = c.base0C;
            blue = c.base0D;
            mauve = c.base0E;
          };
        };

        keys = {
          prefix = keymap.prefix.herdr;
        }
        // keymap.renderHerdr keymap.multiplexer;

        # Nix owns the binary, so `herdr update` cannot succeed and the
        # background version check only produces nags. The agent-detection
        # manifest check writes to the config dir and stays on.
        update.version_check = false;
      };

      tomlFormat = pkgs.formats.toml { };
      rawConfig = tomlFormat.generate "herdr-config.toml" settings;

      # `herdr config check` is hermetic — no $HOME, no network — and exits 1
      # on any unknown key or invalid binding. Running it here turns a keymap
      # typo into a build failure instead of a binding silently disabled at
      # runtime. It is load-bearing rather than decorative: herdr.dev's
      # documentation runs ahead of the packaged release and lists keys and
      # theme tokens this version rejects.
      checkedConfig = pkgs.runCommand "herdr-config.toml" { } ''
        HERDR_CONFIG_PATH=${rawConfig} ${lib.getExe pkgs.herdr} config check
        cp ${rawConfig} "$out"
      '';
    in
    {
      home.packages = [ pkgs.herdr ];

      xdg.configFile."herdr/config.toml".source = checkedConfig;
    };
}
