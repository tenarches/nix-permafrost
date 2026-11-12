{
  # A second login in the guest for pi-durable, apart from `agent`.
  #
  # pi-durable runs its model tool commands over ssh in this guest. `agent`
  # owns everything the owner's other harnesses keep: their sign-in files (the
  # virtiofs shares under /mnt/persist, linked into /home/agent) and the launch
  # credentials. A factory agent that reads untrusted repository text could be
  # told to read and send any of it. `adurable` is the account those commands
  # run as, and it owns none of that.
  #
  # How it is kept apart:
  #
  # - Login is by CA certificate only. There is no authorized_keys entry and
  #   the password is locked. The CA role that signs for it issues the
  #   principal `adurable`, and sshd's default rule (no AuthorizedPrincipalsFile,
  #   see ssh-ca.nix) accepts a certificate whose principal equals the login
  #   name, so a certificate for `agent` or `root` does not log in here and
  #   this one logs in nowhere else.
  # - No supplementary groups: not `users`, not video/render/systemd-journal,
  #   not wheel. Its primary group is its own.
  # - Its home is a disk volume of its own (guest/base.nix, volumes), recreated
  #   on every boot, and there is deliberately no share and nothing under
  #   /mnt/persist for it. What it writes goes when the VM stops and never
  #   reaches the host.
  # - /home/agent and /mnt/persist are 0700 and owned by agent (the rule for
  #   /mnt/persist is in guest/shares.nix). /proc is not hidden: adurable can
  #   list the processes of agent (see "Not done" in docs/reference.md).
  # - The Nix daemon accepts it as a client but it is not a trusted user, as
  #   `agent` is not (see base.nix): a trusted user is root-equivalent.
  flake.modules.nixos.guest-adurable =
    { config, lib, ... }:
    {
      users = {
        groups.adurable.gid = 1001;

        users.adurable = {
          isNormalUser = true;
          uid = 1001;
          group = "adurable";
          home = "/home/adurable";
          homeMode = "0700";

          # Locked, not empty, as for agent in base.nix.
          hashedPassword = "!";

          extraGroups = [ ];
        };
      };

      # Only the two accounts that run commands. Root is always allowed, and
      # `trusted-users` stays root only in base.nix, so neither can set
      # per-invocation substituters or a post-build hook.
      nix.settings.allowed-users = [
        "agent"
        config.users.users.adurable.name
      ];

      # AuthorizedKeysFile in base.nix also names ~/.ssh/authorized_keys, which a
      # process running as adurable could write, and the harvested keys in
      # /etc/ssh/authorized_keys.d are only ever written for agent. For this
      # account both are switched off, so a certificate is the one way in. Agent
      # forwarding is off too: the owner's agent must not be reachable from a
      # session that reads untrusted text. A Match block runs to the next Match
      # or the end of the file, and extraConfig is the last thing in
      # sshd_config. mkAfter keeps the block below every global line that
      # another module adds there at the default order (the slot accounts in
      # slots.nix do the same).
      services.openssh.extraConfig = lib.mkAfter ''
        Match User adurable
          AuthorizedKeysFile none
          AllowAgentForwarding no
      '';

      systemd.tmpfiles.rules = [
        # Same reason as /home/agent in base.nix: the volume mounts as root:root
        # 0755, and the chown that createHome does at activation lands on the
        # directory under the mount. btrfs has no uid mount option, so fix it
        # here, after the mount.
        "d /home/adurable 0700 adurable adurable - -"
        # The directories pi-durable starts commands in. adurable could make
        # them itself; creating them here means the first command does not
        # depend on that.
        "d /home/adurable/work 0700 adurable adurable - -"
        "d /home/adurable/workspaces 0700 adurable adurable - -"
      ];
    };
}
