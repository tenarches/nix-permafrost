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
        if [ -n "$SSH_AUTH_SOCK" ] && [ "$SSH_AUTH_SOCK" != "$HOME/${stableSocket}" ]; then
          ${pkgs.coreutils}/bin/mkdir -p -m 0700 "$HOME/.ssh"
          ${pkgs.coreutils}/bin/ln -sfn "$SSH_AUTH_SOCK" "$HOME/${stableSocket}"
        fi
      '';

      # Every herdr pane and tmux pane is an interactive non-login bash, so this
      # is where the indirection has to be taken up.
      home-manager.users.agent.programs.bash.initExtra = ''
        # Prefer the stable agent socket over whichever one this session was
        # handed, so the value stays good once that connection is gone. -S
        # follows the symlink, so a dangling one — a serial console login, or
        # any session with no forwarding at all — leaves SSH_AUTH_SOCK alone.
        if [ -S "$HOME/${stableSocket}" ]; then
          export SSH_AUTH_SOCK="$HOME/${stableSocket}"
        fi
      '';
    };
}
