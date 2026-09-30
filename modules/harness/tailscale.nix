{
  flake.modules.nixos.harness-tailscale =
    { config, pkgs, ... }:

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
          path = [
            tailscale
            pkgs.jq
          ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;

            # Leave the tailnet on the way out. An ephemeral node that merely
            # stops answering is kept by the control plane for a while, and
            # the name stays taken — so the next launch on this host registers
            # as -1, -2, and the URL drifts. Logging out deletes it at once.
            # Stops before tailscaled does, since this unit is ordered after
            # it. The dash and short timeout keep a control plane that is
            # unreachable at shutdown from holding up the guest's power-off; a
            # killed guest simply falls back to the suffix.
            ExecStop = "-${tailscale}/bin/tailscale logout";
            TimeoutStopSec = 10;
          };

          # The node registers under the OS hostname, which every guest shares,
          # and is renamed here to the per-launch-host name the runner chose so
          # that guests on different hosts do not contend for one name. The
          # rename takes a round trip to the control plane, and `serve` binds
          # its config to the node's name at the moment it is created — so it
          # has to wait for the new name to show up, or it serves a name the
          # node no longer has and every request finds no handler. The control
          # plane appends -1, -2 to a name it still holds for a previous
          # ephemeral node, so the settled name is matched by prefix.
          script = ''
            if [ -s ${hostnameFile} ]; then
              want="$(cat ${hostnameFile})"
              tailscale set --hostname="$want"
              for _ in $(seq 60); do
                name="$(tailscale status --json | jq -r '.Self.DNSName // empty')"
                case "$name" in
                  "$want".* | "$want"-[0-9]*.*) break ;;
                esac
                sleep 1
              done
            fi
            # 3080 is the port dsh-web listens on, set in harness/dsh.nix.
            tailscale serve --bg --https=443 http://127.0.0.1:3080
          '';
        };
      };
    };
}
