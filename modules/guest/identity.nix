{
  # Who the guest is on the network, and the one flag that changes how it is
  # launched. This is what is left of modules/inventory.nix: with a single guest
  # there is no registry to keep, only the handful of values the host side and
  # the guest side both have to agree on.
  flake.modules.nixos.guest-identity =
    { lib, config, ... }:
    let
      cfg = config.permafrost.identity;
    in
    {
      options.permafrost = {
        identity = {
          name = lib.mkOption {
            type = lib.types.str;
            description = ''
              The guest's hostname. Also names its systemd unit
              (`microvm-<name>`), its runtime directory (`/run/microvm-<name>`),
              its host-side image directory (`/var/lib/permafrost/<name>`) and
              its ssh alias, so changing it moves all five together.
            '';
          };

          tapId = lib.mkOption {
            type = lib.types.str;
            description = ''
              Suffix of the tap interface, which is created as
              `microvm-<tapId>`. The `microvm-` prefix is not optional: the host
              bridges `matchConfig.Name = "microvm*"` onto microbr, so a tap
              named anything else is created and then never attached.
            '';
          };

          ip = lib.mkOption { type = lib.types.str; };
          mac = lib.mkOption { type = lib.types.str; };
          vsockCid = lib.mkOption { type = lib.types.int; };

          gateway = lib.mkOption {
            type = lib.types.str;
            default = "192.168.33.1";
            description = "The host's address on microbr.";
          };

          nameservers = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [
              "10.0.7.15"
              "10.0.7.16"
            ];
            description = ''
              Internal resolvers, deliberately with no public fallback.

              networking.useNetworkd pulls in systemd-resolved, which treats
              every server in a scope as interchangeable — there is no
              per-server domain routing without splitting them across links. A
              public resolver listed here therefore gets asked for internal
              names too, and answers NXDOMAIN with the root zone's SOA, whose
              negative TTL is 86400s: one query that lands on it poisons the
              guest's cache for a day. nsswitch's `resolve [!UNAVAIL=return]`
              then returns that NOTFOUND without falling through, so only an
              explicit `dig @10.0.7.15` still works.

              These servers do full public recursion, so nothing is lost.
            '';
          };
        };

        gui = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            Enable microvm.graphics — an in-guest wayland-proxy plus a host-side
            crosvm virtio-gpu device — which buys "ssh in first, then launch
            anything" and Xwayland for X11 clients.

            The guest can already display GUI apps on the host without this:
            `waypipe ssh agent@<ip> bash -l` needs nothing from the flag.

            Off by default because the path is upstream-fragile. It needs a
            Spectrum-patched cloud-hypervisor pinned to 51.0, a crosvm pinned to
            an older vhost-user dialect, and a Mesa kept on crosvm's own glibc
            generation (see flake.nix and modules/_pkgs/crosvm-graphics.nix).
            Turning it on also means building cloud-hypervisor from source, and
            it only works through the runner: the fleet path's
            microvm@<name>.service is a system unit with no compositor to attach
            to. See the preflight check in modules/_pkgs/runner.nix.
          '';
        };
      };

      config = {
        permafrost.identity = {
          name = "permafrost";
          # 'microvm-' + this must fit IFNAMSIZ, so it cannot be the hostname.
          tapId = "pf";
          ip = "192.168.33.10";
          mac = "02:00:00:00:00:10";
          vsockCid = 10;
        };

        assertions = [
          {
            assertion = builtins.stringLength cfg.tapId <= 7;
            message = "permafrost.identity.tapId exceeds 7 characters (max for IFNAMSIZ with the 'microvm-' prefix)";
          }
        ];
      };
    };
}
