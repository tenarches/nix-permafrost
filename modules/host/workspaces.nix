{ lib, ... }:

let
  slots = import ../_lib/slots.nix;
in
{
  # The host half of the workspaces share of the factory slots (guest/slots.nix).
  #
  # Each slot of the guest writes into `path/<slot>` as a host id that no
  # account of the host has (hostIdBase + n, from the id map in
  # _lib/slots.nix). This module makes that tree, gives one group the right to
  # read it, and mounts the tree read-only for the reader at `readerPath`.
  # Nothing else on the host reads or writes the tree.
  #
  # For the fleet host (host-fleet), `count`, `path` and `hostIdBase` come from
  # the guest that the host evaluates, so there is one value. A host that
  # starts the guest with the runner has no guest in its own configuration. The
  # runner makes the same tree itself, and the check `workspaces-ids-agree`
  # compares the defaults of the two sides.
  #
  # The write barrier is the read-only mount, and only that. A slot owns its
  # files and may give the reader group write bits with `chmod`; the mount
  # stops the write. So:
  #
  # - the group `readerGroup` has exactly one kind of member, a service that
  #   reads the workspaces (the `nix_verify` service of pi-durable), and that
  #   service reaches the data through `readerPath` and not through `path`
  #   (`InaccessiblePaths` and `BindReadOnlyPaths` in its unit);
  # - permafrost-workspaces-ro-check fails when the mount is missing or has lost
  #   `ro`, `nosymfollow` or `nosuid`. It is not RemainAfterExit, so every start
  #   of a unit that has `Requires=` and `After=` on it runs the check again, and
  #   a failed check stops that start. The reader unit MUST declare both. A
  #   timer runs the check every minute and shows a mount that was remounted
  #   writable later; `After=` alone would not stop the reader.
  #
  # The reader must not run git on these trees with the repository's own
  # configuration. A slot writes `.git/config` and the hooks, and git runs
  # `core.fsmonitor`, `core.sshCommand`, `core.pager` and
  # `uploadpack.packObjectsHook` from there, as the reader. So there is no
  # `safe.directory`: with it, the one ownership check that git has is gone. A
  # reader that needs git runs it with `-c core.fsmonitor= -c
  # core.hooksPath=/dev/null`, `GIT_CONFIG_GLOBAL=/dev/null` and
  # `GIT_CONFIG_NOSYSTEM=1`. That is a deny list of the keys that are known
  # today, and `.git/config` still supplies the rest, so a parser that reads
  # the tree and does not run git is the better way. "dubious ownership" is the
  # right answer for a tree that the reader does not own.
  #
  # Not closed: a slot can `chmod 700` its tree and hide it from the reader,
  # which then fails and reads nothing wrong. The reader mount does not follow
  # symlinks, so `nix_verify` cannot follow one inside a repository. The share
  # has no quota: the directory should be a dataset with one.
  flake.modules.nixos.host-workspaces =
    {
      config,
      pkgs,
      ...
    }:

    let
      cfg = config.permafrost.host.workspaces;
      names = slots.names {
        inherit (cfg) count userPrefix;
      };
      readerGid = cfg.hostIdBase;
      firstUid = cfg.hostIdBase + 1;
      lastUid = cfg.hostIdBase + cfg.count;
      # The guest as the fleet host evaluates it, when the host has one.
      guestSlots = lib.attrByPath [
        "microvm"
        "vms"
        "permafrost"
        "config"
        "config"
        "permafrost"
        "slots"
      ] null config;
    in
    {
      options.permafrost.host.workspaces = {
        path = lib.mkOption {
          type = lib.types.path;
          default = slots.defaults.hostPath;
          description = ''
            The directory that the share carries, with one directory for each
            slot. Not below /var/lib/permafrost, which `permafrost-gc` empties.
          '';
        };

        readerPath = lib.mkOption {
          type = lib.types.path;
          default = slots.defaults.readerPath;
          description = ''
            Where the reader sees the tree: the same directory, as a read-only
            mount without symlink following. The guest path
            `<home>/workspaces/<repo>` of the slot `f-slotN` is
            `<readerPath>/f-slotN/<repo>` here.
          '';
        };

        readerGroup = lib.mkOption {
          type = lib.types.str;
          default = slots.defaults.readerGroup;
          description = "The group that may read the tree. Its gid is `hostIdBase`.";
        };

        hostIdBase = lib.mkOption {
          type = lib.types.ints.between slots.hostIdMin (slots.hostIdMax - 100);
          default = slots.defaults.hostIdBase;
          description = ''
            Slot n owns its directory as uid and gid `hostIdBase + n`, and the
            reader group has the gid `hostIdBase`. The same number as
            `permafrost.slots.workspaces.hostIdBase` of the guest.
          '';
        };

        count = lib.mkOption {
          type = lib.types.ints.between 1 99;
          default = slots.defaults.count;
          description = "How many slot directories there are. The same number as `permafrost.slots.count`.";
        };

        userPrefix = lib.mkOption {
          type = lib.types.strMatching "[a-z][a-z0-9-]*";
          default = slots.defaults.userPrefix;
          description = "The start of every slot directory name. The same as `permafrost.slots.userPrefix`.";
        };
      };

      config = lib.mkMerge [
        (lib.mkIf (guestSlots != null) {
          permafrost.host.workspaces = {
            count = lib.mkDefault guestSlots.count;
            userPrefix = lib.mkDefault guestSlots.userPrefix;
            path = lib.mkDefault guestSlots.workspaces.hostPath;
            hostIdBase = lib.mkDefault guestSlots.workspaces.hostIdBase;
          };
        })

        {
          users.groups.${cfg.readerGroup}.gid = readerGid;

          fileSystems = slots.readerMount cfg;

          systemd = {
            # The runner path makes the same tree itself (_pkgs/runner.nix), as
            # root, before it starts the guest. Here no runner does, and `d` lines
            # refuse to follow a symlink on the way. No `Z` line and no `R`: what
            # is inside belongs to the slots.
            tmpfiles.rules = [
              "d ${cfg.path} 0750 root ${toString readerGid} - -"
            ]
            ++ lib.imap1 (
              n: name: "d ${cfg.path}/${name} 2750 ${toString (cfg.hostIdBase + n)} ${toString readerGid} - -"
            ) names;

            services = {
              permafrost-workspaces-ro-check = {
                description = "Check that the workspaces are mounted read-only for the reader";
                wantedBy = [ "multi-user.target" ];
                unitConfig.RequiresMountsFor = cfg.readerPath;
                path = [ pkgs.util-linux ];
                # Not RemainAfterExit: the unit is inactive after it ran, so a
                # unit that requires it starts it, and so checks the mount, on
                # each of its own starts.
                serviceConfig.Type = "oneshot";
                script = ''
                  # The last line is the mount on top.
                  seen=$(findmnt -n -o OPTIONS --mountpoint ${lib.escapeShellArg cfg.readerPath} | tail -n 1)
                  if [ -z "$seen" ]; then
                    echo "${cfg.readerPath} is not a mount point" >&2
                    exit 1
                  fi
                  for need in ro nosymfollow nosuid; do
                    case ",$seen," in
                      *",$need,"*) ;;
                      *)
                        echo "${cfg.readerPath} is mounted with '$seen' and lacks $need" >&2
                        exit 1
                        ;;
                    esac
                  done
                '';
              };

              # A look at who owns what, once a day. A file whose owner or group is
              # outside the ids of the slots means that an account of the host, or an
              # id that the map does not know, wrote into the share. It changes
              # nothing: it only writes a warning for each finding. File names are
              # slot data, so they pass through `tr` and cannot start a line of
              # their own in the journal.
              permafrost-workspaces-audit = {
                description = "Look for files in the workspaces that no slot owns";
                path = [
                  pkgs.findutils
                  pkgs.coreutils
                ];
                serviceConfig = {
                  Type = "oneshot";
                  SyslogIdentifier = "permafrost-ws-audit";
                  ProtectSystem = "strict";
                  ProtectHome = true;
                  PrivateTmp = true;
                  PrivateNetwork = true;
                  NoNewPrivileges = true;
                };
                script = ''
                  found=0
                  while IFS= read -r line; do
                    found=$((found + 1))
                    echo "<4>owner outside the slot ids: $line"
                  done < <(
                    find ${lib.escapeShellArg cfg.path} -mindepth 1 \
                      \( -uid -${toString firstUid} -o -uid +${toString lastUid} \
                         -o -gid -${toString readerGid} -o -gid +${toString lastUid} \) \
                      -printf '%U:%G %p\0' | tr -c '[:print:]\0' '?' | tr '\0' '\n'
                  )
                  echo "found $found"
                '';
              };
            };

            timers.permafrost-workspaces-ro-check = {
              wantedBy = [ "timers.target" ];
              timerConfig.OnCalendar = "minutely";
            };

            timers.permafrost-workspaces-audit = {
              wantedBy = [ "timers.target" ];
              timerConfig = {
                OnCalendar = "daily";
                Persistent = true;
              };
            };
          };
        }
      ];
    };
}
