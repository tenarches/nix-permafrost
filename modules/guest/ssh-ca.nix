{
  # Root login by SSH certificate, for whoever launched the guest.
  #
  # The guest has no interactive root otherwise: guest/base.nix removes sudo,
  # locks the agent's password, and trims nix's trusted-users, and the runner
  # no longer seeds root's authorized_keys. That last one was deliberate —
  # the guest carries a forwarded agent, so a bare key in root's
  # authorized_keys made `ssh root@localhost` from inside the guest a way back
  # to root. A certificate is not, because the guest cannot mint one.
  #
  # Certificates only, matching what the CA on the other end already issues.
  # No AuthorizedPrincipalsFile, so OpenSSH's default rule applies: a
  # certificate is accepted when one of its valid_principals equals the login
  # name. A cert carrying `root` logs in as root and nothing else does; that
  # pairs with PermitRootLogin = "prohibit-password" in guest/base.nix.
  #
  # Host certificates are deliberately not part of this. The guest presents a
  # fresh host key on every boot and the launcher's ssh_config already answers
  # for that with StrictHostKeyChecking no / UserKnownHostsFile /dev/null
  # scoped to the guest's subnet (see modules/_pkgs/tools.nix). Signing an
  # ephemeral host key would mean handing the CA's private half to the
  # launcher, which is a much larger ask than this buys.
  #
  # Nothing here is site-specific: with no CA configured the module is inert
  # and sshd is left exactly as it was. A fork gets no CA it did not choose,
  # which is the point — see ssh-ca-novuscotia.nix for how one is supplied,
  # and delete that file to have none.
  flake.modules.nixos.guest-ssh-ca =
    { config, lib, ... }:

    let
      cfg = config.permafrost.ssh;
    in
    {
      options.permafrost.ssh.trustedUserCAKeys = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        example = lib.literalExpression "../../certs/trusted_ssh_ca.pub";
        description = ''
          A file of SSH CA public keys whose certificates sshd will accept, one
          per line, or `null` to trust no CA.

          The file is copied into the Nix store, so it must hold public halves
          only. Multiple CAs are fine — `TrustedUserCAKeys` reads every line.

          With this unset the guest has no interactive root at all. That is the
          intended default for a fork: it should not inherit trust in someone
          else's certificate authority just by cloning the repository.
        '';
      };

      config = lib.mkIf (cfg.trustedUserCAKeys != null) {
        services.openssh.settings.TrustedUserCAKeys = "${cfg.trustedUserCAKeys}";
      };
    };
}
