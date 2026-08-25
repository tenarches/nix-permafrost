{
  flake.modules.homeManager.agent-ssh-novuscotia =
    _:

    {
      # Site-specific. Reaches the Gitea SSH endpoint through Consul service
      # discovery rather than the public name's default port. Delete this file in a
      # fork to get the generic ssh config only.
      #
      # The user is `gitea`, not the `git` that most Gitea deployments use —
      # this one runs under its own name, and it is the only one the endpoint
      # accepts. Leaving it unset is not an option either: ssh would fall back
      # to the local account, `agent`, which is refused just the same.
      #
      # The agent-skills flake input spells `gitea@` in its URL, and an
      # explicit user there beats ssh_config, so that input kept resolving
      # while a bare `git clone code-ssh.novuscotia.com:...` did not.
      permafrost.ssh.dropins."10-novuscotia" = ''
        Host code-ssh.novuscotia.com
          Port 2222
          Hostname gitea-ssh.service.consul
          User gitea
      '';
    };
}
