{
  flake.modules.homeManager.agent-ssh-novuscotia =
    _:

    {
      # Site-specific. Reaches the Gitea SSH endpoint through Consul service
      # discovery rather than the public name's default port. Delete this file in a
      # fork to get the generic ssh config only.
      permafrost.ssh.dropins."10-novuscotia" = ''
        Host code-ssh.novuscotia.com
          Port 2222
          Hostname gitea-ssh.service.consul
          User git
      '';
    };
}
