{
  # Site-specific. Delete this file in a fork: the token is ours and the
  # service it opens is only reachable on this network, so a fork inherits a
  # credential it cannot use and did not ask for.
  #
  # The crawl4ai skill the agents use talks to a private crawl4ai deployment
  # behind token auth, and reads the token from CRAWL4AI_AUTH_TOKEN. Without it
  # the skill is present but every call it makes is rejected.
  #
  # home.sessionVariables rather than environment.variables, which is what
  # harness/dsh.nix uses for its own three: this one belongs to the agent and
  # not to the system, and there is no reason for root's environment to carry
  # it. Home Manager renders these into hm-session-vars.sh, which ~/.profile
  # sources — so it reaches an `ssh permafrost` login and, because the dsh-web
  # unit starts through `bash -l`, the harness as well. That is the same seam
  # the login-shell fix in harness/dsh.nix opened; before it, a user unit would
  # not have seen this.
  #
  # The boundary, measured against EDITOR, which this same file delivers: an
  # interactive `ssh permafrost`, a login shell and the dsh-web unit all see
  # `nvim`, while a one-shot `ssh permafrost <cmd>` sees the system default
  # `nano` — that form runs neither a login nor an interactive shell, so
  # ~/.profile never runs and this variable is absent. Reach for
  # `ssh permafrost -t 'bash -lc "..."'` if a scripted invocation needs it.
  #
  # The value is committed in the clear, on the stated grounds that it is
  # low-risk. If that ever stops being true, this is the file to move behind
  # sops — the option it sets takes a string from anywhere.
  flake.modules.homeManager.agent-crawl4ai-novuscotia =
    _:

    {
      home.sessionVariables.CRAWL4AI_AUTH_TOKEN = "dummy";
    };
}
