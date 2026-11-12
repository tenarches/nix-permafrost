{ lib, ... }:

let
  slots = import ../_lib/slots.nix;
in
{
  # One login for each factory slot, apart from `agent` and `adurable`.
  #
  # A factory slot is where pi-durable runs the commands of one factory. Each
  # slot is its own account, so two factories that read untrusted text in the
  # same guest cannot read each other's files. Everything here is generated
  # from `permafrost.slots.count`, in the shape of adurable.nix.
  #
  # How a slot is kept apart:
  #
  # - Login is by CA certificate only. sshd's default rule accepts a
  #   certificate whose principal equals the login name, so a certificate for
  #   `f-slot1` logs in as `f-slot1` and nowhere else, and one for `adurable`
  #   or `root` does not log in here. The password is locked and
  #   AuthorizedKeysFile is `none`, so a key a slot writes opens nothing.
  # - No supplementary groups. Each slot has a primary group of its own, and
  #   nothing else is in it.
  # - One home volume for all slots (guest/base.nix), mounted at `homeRoot`
  #   and recreated on every boot. Each home is 0700, and `homeRoot` is 0711,
  #   so a slot can reach its own home and cannot list the others. Nothing a
  #   slot writes there reaches the host.
  # - sshd gives each slot its own TMPDIR inside its home. /tmp is one shared
  #   volume, and a slot would see the file names of the others in it.
  # - The files a slot makes get mode 0640 and 0750 (umask 0027), so a reader
  #   in the group of the file can read them. Other accounts still get nothing.
  # - The one thing of a slot that reaches the host is its `workspaces`
  #   directory. A virtiofs share carries the workspaces of every slot to a
  #   directory of the host (`workspaces.hostPath`), and each slot sees only
  #   its own part, bind mounted into its home. The share is mounted below
  #   /mnt/factory, which only root enters, so a slot that opens its own
  #   directory to others still hides it from them. The guest ids of the slots
  #   map to host ids that no account of a host has (_lib/slots.nix,
  #   `virtiofsdArgs`), so no real host user owns a file of a slot. The host
  #   reads the files through a group and a read-only mount (host/workspaces.nix).
  #
  # Not closed: /proc is not hidden, so a slot can list the processes of the
  # others, with their command lines. /tmp is shared, and only ssh sessions get
  # the TMPDIR above. There is no CPU, memory or disk limit for a slot, and a
  # slot that fills the home volume starves the others. Unix sockets (abstract
  # ones too) and the Nix store are shared between all accounts. Guest root can
  # still change a file that exists in the share, because virtiofsd acts with
  # its own rights after the guest kernel has allowed the call, and a slot can
  # `chmod` its files open or closed: the read-only mount on the host is the
  # only thing that stops a write there. A symlink in a workspace works for the
  # slot, and the host reader does not follow it.
  flake.modules.nixos.guest-slots =
    {
      config,
      pkgs,
      ...
    }:

    let
      cfg = config.permafrost.slots;
      ws = cfg.workspaces;
      slotNames = slots.names cfg;
      uidOf = n: slots.uid cfg n;
      numbers = lib.range 1 cfg.count;
      homeOf = name: "${cfg.homeRoot}/${name}";
      firstUid = uidOf 1;
      lastUid = uidOf cfg.count;
      # One attribute for each slot, named by the slot account.
      perSlot = f: lib.listToAttrs (map (n: lib.nameValuePair (slots.name cfg n) (f n)) numbers);
    in
    {
      options.permafrost.slots = {
        count = lib.mkOption {
          type = lib.types.ints.between 1 99;
          default = slots.defaults.count;
          description = ''
            How many slot accounts the guest has. The accounts are named
            `<userPrefix>1` to `<userPrefix><count>`, with uid `uidBase + n`.
          '';
        };

        userPrefix = lib.mkOption {
          type = lib.types.strMatching "[a-z][a-z0-9-]*";
          default = slots.defaults.userPrefix;
          description = "The start of every slot account name.";
        };

        uidBase = lib.mkOption {
          type = lib.types.ints.between 1100 60000;
          default = 2000;
          description = ''
            Slot n has uid and gid `uidBase + n`. The range starts above the
            accounts of this repository (1000 to 1002) and stays below the
            dynamic ids of systemd (61184 and up).
          '';
        };

        homeRoot = lib.mkOption {
          type = lib.types.path;
          default = "/home/slots";
          description = "Mount point of the one volume that holds every slot home.";
        };

        homeVolumeSizeMiB = lib.mkOption {
          type = lib.types.int;
          default = 131072; # 128 GiB
          description = ''
            Size of the slot home volume in MiB. The image is sparse, so this
            is a cap and not a cost.
          '';
        };

        workspaces = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = ''
              Mount the workspaces share, and give each slot its own part of it
              at `<home>/workspaces`. The share itself comes from the launch
              module (launch-runner.nix or launch-fleet.nix), or from the node
              of a check.
            '';
          };

          hostPath = lib.mkOption {
            type = lib.types.path;
            default = slots.defaults.hostPath;
            description = ''
              The directory of the host that the share carries, with one
              directory for each slot. It is not below /var/lib/permafrost,
              because `permafrost-gc` deletes everything there that has no
              running unit.
            '';
          };

          hostIdBase = lib.mkOption {
            type = lib.types.ints.between slots.hostIdMin (slots.hostIdMax - 100);
            default = slots.defaults.hostIdBase;
            description = ''
              Slot n writes into the share as host uid and gid `hostIdBase +
              n`, and the host group that reads the files is `hostIdBase`
              itself. The range is above the container ids of systemd and below
              its foreign range (0x7FFF0000), so no account of a host has one of
              these numbers. Every host id outside the slot ids is shown to the
              guest as nobody. Changing it later moves the owner of every file
              in the share.
            '';
          };
        };
      };

      config = lib.mkMerge [
        {
          users = {
            groups = perSlot (n: {
              gid = uidOf n;
            });

            users = perSlot (n: {
              isNormalUser = true;
              uid = uidOf n;
              group = slots.name cfg n;
              home = homeOf (slots.name cfg n);
              homeMode = "0700";

              # Locked, not empty, as for agent in base.nix.
              hashedPassword = "!";

              # No wheel, no users, no video, render or systemd-journal.
              extraGroups = [ ];
            });
          };

          # Slots are Nix clients and run builds. `trusted-users` stays root only
          # in base.nix, so a slot cannot set per-invocation substituters or a
          # post-build hook. This list merges with the entries in base.nix and
          # adurable.nix.
          nix.settings.allowed-users = slotNames;

          # AuthorizedKeysFile in base.nix names ~/.ssh/authorized_keys, which a
          # slot could write, so it is switched off for each slot, and a
          # certificate is the one way in. No forwarding of any kind: the owner's
          # agent must not be reachable from a session that reads untrusted text,
          # and a forwarded listener would be a socket owned by a slot. TMPDIR is
          # a literal for each slot because SetEnv does not expand %u, which is
          # why there is one block per slot. A Match block runs to the next Match
          # or the end of the file, so everything here is mkAfter: a global line
          # that another module adds must stay above the first Match block.
          services.openssh.extraConfig = lib.mkAfter (
            lib.concatMapStrings (name: ''
              Match User ${name}
                AuthorizedKeysFile none
                AuthorizedPrincipalsFile none
                AllowAgentForwarding no
                AllowTcpForwarding no
                AllowStreamLocalForwarding no
                X11Forwarding no
                PermitTunnel no
                PermitUserRC no
                SetEnv TMPDIR=${homeOf name}/tmp
            '') slotNames
          );

          # An ssh session of an account outside this range runs with umask 0022
          # (seen in the VM check), and a systemd --user unit with the same. A
          # slot should make files that the group of the file can read and that
          # others cannot. Two places set 0027 for slot uids and for nobody else:
          # the PAM session of ssh and login, and the user manager of each slot,
          # which starts the processes that never pass through sshd.
          security.pam.services = lib.genAttrs [ "sshd" "login" ] (service: {
            rules.session = {
              # The control skips the next rule (default=1) for every uid outside
              # the slot range, and falls through to it inside the range.
              slot-umask-range = {
                order = config.security.pam.services.${service}.rules.session.umask.order + 1;
                control = "[success=ok default=1]";
                modulePath = "${config.security.pam.package}/lib/security/pam_succeed_if.so";
                args = [
                  "quiet"
                  "uid"
                  ">="
                  (toString firstUid)
                  "uid"
                  "<="
                  (toString lastUid)
                ];
              };
              slot-umask = {
                order = config.security.pam.services.${service}.rules.session.umask.order + 2;
                control = "optional";
                modulePath = "${config.security.pam.package}/lib/security/pam_umask.so";
                settings.umask = "0027";
              };
            };
          });

          # systemd.units and not systemd.services: the module adds PATH,
          # LOCALE_ARCHIVE and TZDIR to every service it writes, and a drop-in
          # with them would replace the environment of the user manager.
          systemd.units = lib.listToAttrs (
            map (n: {
              name = "user@${toString (uidOf n)}.service";
              value = {
                overrideStrategy = "asDropin";
                text = ''
                  [Service]
                  UMask=0027
                '';
              };
            }) numbers
          );

          systemd.tmpfiles.rules = [
            # The volume mounts as root:root 0755. Traversable, so a slot can
            # reach its own home, and not listable.
            "d ${cfg.homeRoot} 0711 root root - -"
          ]
          ++ lib.concatMap (name: [
            # Same reason as /home/adurable in adurable.nix: the chown that
            # createHome does at activation lands under the mount, so fix the
            # owner here, after the mount.
            "d ${homeOf name} 0700 ${name} ${name} - -"
            # TMPDIR for ssh sessions (see the Match blocks above), and the
            # directory the jobs of a slot start in.
            "d ${homeOf name}/tmp 0700 ${name} ${name} - -"
            "d ${homeOf name}/work 0700 ${name} ${name} - -"
          ]) slotNames;
        }

        (lib.mkIf ws.enable {
          # The options of the share, and the bind mount of each slot's part
          # (_lib/slots.nix, workspaceMounts). The share itself arrives from the
          # launch module, with its device and type.
          fileSystems = slots.workspaceMounts cfg;

          # Slots reach their own part through the bind mounts and nothing else
          # of the share. The mount unit makes the parent of a mount point
          # 0755 first, and `d` corrects an existing directory (the precedent is
          # /mnt/persist in shares.nix). The mount point `<home>/workspaces` of
          # a slot has no line here: a mode on it would change the host
          # directory.
          systemd.tmpfiles.rules = [ "d ${slots.shareRoot} 0700 root root - -" ];

          # All the isolation between slots in the share rests on the mode of
          # its parent. Nothing may log in before it is right, so a failed
          # tmpfiles run leaves the guest without a slot and not with an open
          # share. A failed guard stops sshd for everyone, root too, and the
          # serial console is then the way in.
          systemd.services.permafrost-factory-guard = {
            description = "Check that only root can enter ${slots.shareRoot}";
            requiredBy = [ "sshd.service" ];
            before = [ "sshd.service" ];
            after = [ "systemd-tmpfiles-setup.service" ];
            unitConfig.RequiresMountsFor = slots.shareMount;
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
            };
            script = ''
              seen=$(${pkgs.coreutils}/bin/stat -c '%a %u %g' ${slots.shareRoot})
              if [ "$seen" != "700 0 0" ]; then
                echo "${slots.shareRoot} is '$seen' and not '700 0 0'" >&2
                exit 1
              fi
            '';
          };
        })
      ];
    };
}
