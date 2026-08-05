_:

{
  # Site-specific. Reaches the Gitea SSH endpoint through Consul service
  # discovery rather than the public name's default port. Drop this module from
  # the import list in agent-base.nix to get the fleet-generic ssh config only.
  permafrost.ssh.dropins."10-novuscotia" = ''
    Host code-ssh.novuscotia.com
      Port 2222
      Hostname gitea-ssh.service.consul
  '';
}
