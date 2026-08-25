{
  flake.modules.nixos.guest-identity-novuscotia =
    _:

    {
      # Site-specific. A DNS entry on the internal resolvers points this name at
      # the guest's address, which lets the web UI be reached by name instead of
      # by IP. Delete this file in a fork — everything works without it, and a
      # fork's resolvers will not know the name.
      #
      # Declared once because three things have to agree on it: the certificate
      # the launcher asks Vault for, the authorities caddy serves, and the ones
      # dsh's /api Host-header fence accepts. See guest/identity.nix.
      permafrost.identity.fqdn = "permafrost.home.lan";
    };
}
