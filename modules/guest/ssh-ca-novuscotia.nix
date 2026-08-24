{
  flake.modules.nixos.guest-ssh-ca-novuscotia =
    _:

    {
      # Site-specific. Trusts the homelab SSH certificate authority, the same
      # one nix-nexus carries at certs/trusted_ssh_ca.pub, so a certificate
      # already signed for that fleet logs into this guest too. Delete this
      # file in a fork to trust no CA — or point the option at your own.
      #
      # Certificates come from Vault, and getting one is a manual step that
      # lives with the CA rather than in this repo:
      #
      #   vault write -field=signed_key ssh-client-signer/sign/adminrole \
      #     public_key=@~/.ssh/id_ecdsa.pub valid_principals=root ttl=8h \
      #     > ~/.ssh/id_ecdsa-cert.pub
      #
      # `root` is the principal that matters — OpenSSH matches it against the
      # login name, and root is the only account here a certificate can reach.
      #
      # The certificate belongs on the personal agent, never the permafrost
      # one. The runner forwards permafrost-agent.sock into the guest, which
      # holds the agentic key alone; keeping the signed identity out of it is
      # what stops the guest from being able to log into itself as root.
      permafrost.ssh.trustedUserCAKeys = ../../certs/trusted_ssh_ca.pub;
    };
}
