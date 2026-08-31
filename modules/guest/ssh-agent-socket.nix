{
  # A stable path to the forwarded ssh agent, for processes that outlive the
  # connection that forwarded it.
  #
  # OpenSSH 10 gives every inbound connection its own agent socket under
  # ~/.ssh/agent/ and removes it when that connection ends. A login shell is
  # fine — it *is* the connection — but anything still running afterwards is
  # not. `herdr --remote` is the case that exposed it: the herdr server is a
  # daemon and every pane is one of its children, so every pane inherits
  # whichever socket path belonged to the connection that first started the
  # server. Reattach later over a new connection and the panes are still
  # pointed at a socket that no longer exists, while the live one never reaches
  # them — `ssh-add -l` in a pane reports no agent, and the same command from a
  # plain `ssh permafrost` reports the key. tmux has the identical problem
  # across a reattach.
  #
  # The fix is one level of indirection. sshrc runs for every inbound session —
  # interactive, `ssh host cmd`, and herdr's own server bootstrap alike — as the
  # user, with SSH_AUTH_SOCK already set and before any shell rc, so it is the
  # one place that always sees the current socket. It points a fixed symlink at
  # it, and shells export the fixed path rather than the real one. That is what
  # makes a pane survive a reconnect: the symlink moves under it and the
  # variable never has to change.
  #
  # The relink only happens when the current target is dead. Unconditional
  # last-writer-wins is what shipped first, and it dangles avoidably: with
  # connections A then B open, the link tracks B, and when B closes sshd
  # removes B's socket — leaving the link dead while A's socket is still
  # alive. Repointing only a broken link means a new connection never steals
  # a working one, and every inbound session still heals a dangling one.
  #
  # Nothing host-side is involved. ~/.ssh is guest-local — every share is
  # declared by the harness that needs it and none of them is .ssh — so this
  # writes only into the ephemeral guest home.
  flake.modules.nixos.guest-ssh-agent-socket =
    { pkgs, ... }:
    let
      stableSocket = ".ssh/agent.sock";
    in
    {
      # Defining an sshrc suppresses sshd's built-in xauth handling. That costs
      # nothing here: the guest serves X11Forwarding no.
      environment.etc."ssh/sshrc".text = ''
        # Managed by nix-permafrost. See modules/guest/ssh-agent-socket.nix.
        #
        # Runs under /bin/sh for every session sshd sets up, so keep it POSIX
        # and keep it quiet — anything printed here lands in front of the
        # session's own output.
        #
        # -S follows the symlink, so the relink is skipped while the current
        # target is a live socket — see the header for why.
        if [ -n "$SSH_AUTH_SOCK" ] && [ "$SSH_AUTH_SOCK" != "$HOME/${stableSocket}" ] \
          && [ ! -S "$HOME/${stableSocket}" ]; then
          ${pkgs.coreutils}/bin/mkdir -p -m 0700 "$HOME/.ssh"
          ${pkgs.coreutils}/bin/ln -sfn "$SSH_AUTH_SOCK" "$HOME/${stableSocket}"
        fi
      '';

      # bashrcExtra rather than initExtra: home-manager places initExtra below
      # .bashrc's interactive guard, and the dsh web UI's bash tool runs under
      # `bash -l -c` — a login shell that is not interactive, which sources
      # .bash_profile → .bashrc but returns at the guard. bashrcExtra sits
      # above it, so herdr/tmux panes and the web UI's shells alike take up
      # the indirection.
      home-manager.users.agent.programs.bash.bashrcExtra = ''
        # Prefer the stable agent socket over whichever one this session was
        # handed, so the value stays good once that connection is gone. -L not
        # -S: a link that dangles right now heals under the shell when the
        # next connection arrives — that is the point of the indirection. Only
        # a session with no forwarding history at all — a serial console login
        # on a fresh boot, before any symlink exists — leaves SSH_AUTH_SOCK
        # alone.
        if [ -L "$HOME/${stableSocket}" ]; then
          export SSH_AUTH_SOCK="$HOME/${stableSocket}"
        fi
      '';
    };
}
