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
    # on the host and delivers it over a root-only share at /run/launch — see
    # the runner — because a long-lived credential in this guest would be one
    # any agent running in it could read. When no key was delivered every unit
    # below is skipped, and the guest simply is not on the tailnet.
    #
    # The local API socket is closed to the factory slots. tailscaled runs as
    # root, so a call that dials on behalf of the caller (`tailscale nc`) leaves
    # from a uid that the egress table does not filter, and a slot could reach
    # the tailnet that the table denies (100.64.0.0/10). The unit's own runtime
    # directory is 0755 and the socket in it is 0666. Here the directory is
    # root:tailscale 0750, so only root and the group `tailscale` (agent, which
    # reads the status) can reach the socket; a slot gets EACCES on connect.
    #
    # Access control belongs to the tailnet's ACL, not to this file: the node is
    # tagged by the key that registered it, and the tag should be granted
    # inbound 443 from the people who use it and no outbound access at all.
    let
      launchDir = "/run/launch";
      authKey = "${launchDir}/authkey";
      hostnameFile = "${launchDir}/hostname";

      # ConditionPathExists rather than a shell test, so a launch with no key
      # skips the unit outright and the skip is visible in `systemctl status`.
      # RequiresMountsFor because the condition is otherwise evaluated before
      # the virtiofs share is mounted, and a key that was delivered would be
      # silently ignored.
      onlyWithKey = {
        RequiresMountsFor = launchDir;
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
      users.groups.tailscale = { };
      users.users.agent.extraGroups = [ "tailscale" ];

      systemd.services = {
        tailscaled = {
          unitConfig = onlyWithKey;
          serviceConfig = {
            # The directory is closed from the moment it exists, root:root, and
            # opened to the group once the daemon is up.
            RuntimeDirectoryMode = "0750";
            ExecStartPost = "${pkgs.coreutils}/bin/chgrp tailscale /run/tailscale";
          };
        };
        tailscaled-autoconnect.unitConfig = onlyWithKey;

        tailscale-serve = {
          description = "Serve the dsh web UI on the tailnet";
          # Ordered directly after tailscaled as well as its autoconnect unit.
          # Ordering through autoconnect alone does not hold at shutdown:
          # that unit has already exited by then, an inactive unit is not in
          # the shutdown transaction, and with it goes the chain. tailscaled
          # was stopped first, and the logout below ran against a dead daemon.
          after = [
            "tailscaled.service"
            "tailscaled-autoconnect.service"
            "network-online.target"
          ];
          requires = [
            "tailscaled.service"
            "tailscaled-autoconnect.service"
          ];
          wants = [ "network-online.target" ];
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
            TimeoutStopSec = 15;
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
