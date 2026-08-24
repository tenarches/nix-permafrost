{
  flake.modules.homeManager.agent-bash =
    { pkgs, ... }:

    {
      # Core terminal utilities the prompt and day-to-day CLI work assume.
      home.packages = with pkgs; [
        bc # Basic calculator
        calc # Arbitrary precision calculator
        util-linux # Provides 'cal', and friends
      ];

      programs.bash = {
        enable = true;

        shellAliases = {
          ".." = "cd ..";
          "..." = "cd ../..";
          "ll" = "ls -ltr";
          "lrt" = "ls -ltr";
        };

        historyControl = [
          "ignoreboth"
          "erasedups"
        ];
        historySize = 100000000;
        historyFileSize = 100000000;

        shellOptions = [
          "histappend"
          "extglob"
          "globstar"
          "checkjobs"
        ];

        enableCompletion = true;

        initExtra = ''
          # ------------------------------------------------------------------
          # Custom Prompt: "The Stacked Professional"
          # ------------------------------------------------------------------

          # Git branch with a status indicator
          parse_git_branch() {
            # Returns: (master *) or (main)
            local branch
            branch=$(git branch 2> /dev/null | sed -e '/^[^*]/d' -e 's/* \(.*\)/\1/')
            if [ -n "$branch" ]; then
              local status=""
              # Check for uncommitted changes
              if [[ $(git status --porcelain 2> /dev/null) ]]; then
                status="*"
              fi
              echo " ($branch$status)"
            fi
          }

          # Exit-status colours for the prompt arrow (raw escape codes, no readline
          # markers — set_bash_prompt adds the \[ \] wrappers).
          GREEN="\033[38;5;64m"
          RED="\033[38;5;124m"

          # Build the prompt dynamically so the arrow can carry the exit status
          set_bash_prompt() {
            local exit_status=$?
            local symbol_color

            if [ $exit_status -eq 0 ]; then
              symbol_color="$GREEN"
            else
              symbol_color="$RED"
            fi

            PS1="\[\033[38;5;240m\][\A] \[\033[38;5;64m\]\u@\h \[\033[38;5;33m\]\w\[\033[38;5;135m\]\$(parse_git_branch)\[\033[0m\]\n\[''${symbol_color}\]➜\[\033[0m\] "
          }

          # Prepend to PROMPT_COMMAND to preserve other hooks (like direnv)
          PROMPT_COMMAND="set_bash_prompt''${PROMPT_COMMAND:+; ''${PROMPT_COMMAND}}"

          # Load legacy aliases if they exist
          test -s ~/.alias && . ~/.alias || true

          # devenv native auto-activation: entering a trusted directory that
          # contains a devenv.nix activates its environment, with no .envrc and no
          # direnv involved. Trust is granted per project with `devenv allow`.
          # Guarded so a profile without devenv on PATH does not print a
          # command-not-found on every interactive shell.
          if command -v devenv >/dev/null 2>&1; then
            eval "$(devenv hook bash)"
          fi
        '';
      };
    };
}
