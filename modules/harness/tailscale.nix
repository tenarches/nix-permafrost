{
  flake.modules.nixos.harness-tailscale =
    { config, ... }:

    # Puts the guest on the tailnet and serves the dsh web UI there.
    #
    # Tailscale supplies the two things the UI needs that a private address
    # cannot: a browser-trusted certificate for a real name, which makes the
    # origin a secure context (the SPA calls `crypto.randomUUID()`), and a route
    # to it that does not depend on an ssh tunnel. `tailscale serve` terminates
    # the https itself and proxies to dsh's loopback listener, so nothing else
    # has to hold a certificate.
    #
    # The auth key is not configured here. The launcher mints a single-use key
    # on the host and delivers it over a root-only share at /run/tailnet — see
    # the runner — because a long-lived credential in this guest would be one
    # any agent running in it could read. When no key was delivered every unit
    # below is skipped, and the guest simply is not on the tailnet.
    #
    # Access control belongs to the tailnet's ACL, not to this file: the node is
    # tagged by the key that registered it, and the tag should be granted
    # inbound 443 from the people who use it and no outbound access at all.
    let
      tailnetDir = "/run/tailnet";
      authKey = "${tailnetDir}/authkey";
      hostnameFile = "${tailnetDir}/hostname";

      # ConditionPathExists rather than a shell test, so a launch with no key
      # skips the unit outright and the skip is visible in `systemctl status`.
      # RequiresMountsFor because the condition is otherwise evaluated before
      # the virtiofs share is mounted, and a key that was delivered would be
      # silently ignored.
      onlyWithKey = {
        RequiresMountsFor = tailnetDir;
        ConditionPathExists = authKey;
      };

      tailscale = config.services.tailscale.package;
    in

    {
      services.tailscale = {
        enable = true;
        authKeyFile = authKey;

        # The guest's resolvers are pinned to the lab's own; tailscale must not
        # rewrite them.
        extraUpFlags = [ "--accept-dns=false" ];
      };

      # No `--operator`, deliberately: the agent user gets read-only status and
      # no way to change the node, its serve config, or its ACL tag.
      systemd.services = {
        tailscaled.unitConfig = onlyWithKey;
        tailscaled-autoconnect.unitConfig = onlyWithKey;

        tailscale-serve = {
          description = "Serve the dsh web UI on the tailnet";
          after = [ "tailscaled-autoconnect.service" ];
          requires = [ "tailscaled-autoconnect.service" ];
          wantedBy = [ "multi-user.target" ];
          unitConfig = onlyWithKey;
          path = [ tailscale ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };

          # The node registers under the OS hostname, which every guest shares,
          # and is renamed here to the per-launch-host name the runner chose so
          # that guests on different hosts do not contend for one name. The
          # rename lands within a second of joining; the URL is stable from
          # then on.
          script = ''
            if [ -s ${hostnameFile} ]; then
              tailscale set --hostname="$(cat ${hostnameFile})"
            fi
            # 3080 is the port dsh-web listens on, set in harness/dsh.nix.
            tailscale serve --bg --https=443 http://127.0.0.1:3080
          '';
        };
      };
    };
}
