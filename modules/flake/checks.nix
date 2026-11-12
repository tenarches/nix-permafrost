{ config, lib, ... }:
let
  guestSystem = config.flake.nixosConfigurations.permafrost;
  guest = guestSystem.config;
  hostSystem = config.flake.nixosConfigurations.permafrost-host;
  host = hostSystem.config;
  slotLib = import ../_lib/slots.nix;
in
{
  # The VM checks of the guest modules. Each one boots plain NixOS nodes with a
  # few of the modules under test, never the guest itself (no microvm, no
  # volumes): what a check proves is the behaviour of those modules. The test
  # files are under modules/_checks, whose underscore keeps import-tree from
  # loading them as flake-parts modules (the same rule as _pkgs and _lib).
  #
  # The eval checks read the real guest, which the VM nodes are not: they hold
  # the facts that the VM check had to assume for its nodes.
  perSystem =
    { pkgs, self', ... }:
    let
      # A check that passes when every assertion holds. `assert` makes the
      # evaluation of the derivation fail with the message of the first miss.
      evalCheck =
        name: assertions:
        let
          failed = lib.filter (a: !a.assertion) assertions;
        in
        assert lib.assertMsg (failed == [ ])
          "${name}: ${lib.concatMapStringsSep "; " (a: a.message) failed}";
        pkgs.runCommand "check-${name}" { } "touch $out";

      # The share as the fleet host declares it for the guest.
      fleetShare = lib.findFirst (
        s: s.tag == slotLib.shareTag
      ) null host.microvm.vms.permafrost.config.config.microvm.shares;
      slotCfg = guest.permafrost.slots;
      virtiofsdArgs = slotLib.virtiofsdArgs slotCfg;
      hostPathText = slotCfg.workspaces.hostPath;
      hostCfg = host.permafrost.host.workspaces;
      readerMountPoints = slotLib.readerMountPoints hostCfg;

      # What the id map says about every id, read from the flags. A rule is
      # `type:a:b[:c]`: `map` is guest a to host b for c ids, `forbid-guest` is
      # the guest ids a to a+b, `squash-host` is the host ids a to a+c.
      pairsOf =
        args:
        let
          go =
            i:
            lib.optional (i < lib.length args) {
              flag = lib.elemAt args i;
              rule = lib.splitString ":" (lib.elemAt args (i + 1));
            }
            ++ lib.optionals (i + 2 < lib.length args) (go (i + 2));
        in
        go 0;
      rulesFor = flag: map (p: p.rule) (lib.filter (p: p.flag == flag) (pairsOf virtiofsdArgs));
      num = lib.toInt;
      # [ start end ) of each rule, on the guest side and on the host side.
      guestRanges =
        rules:
        map (
          r:
          if lib.head r == "map" then
            {
              start = num (lib.elemAt r 1);
              len = num (lib.elemAt r 3);
            }
          else
            {
              start = num (lib.elemAt r 1);
              len = num (lib.elemAt r 2);
            }
        ) (lib.filter (r: lib.head r != "squash-host") rules);
      hostRanges =
        rules:
        map (
          r:
          if lib.head r == "map" then
            {
              start = num (lib.elemAt r 2);
              len = num (lib.elemAt r 3);
            }
          else
            {
              start = num (lib.elemAt r 1);
              len = num (lib.elemAt r 3);
            }
        ) (lib.filter (r: lib.head r == "map" || lib.head r == "squash-host") rules);
      # The ranges follow each other from 0 to the last id (2^32 - 1, which is
      # not an id), with no gap and no overlap.
      tiles =
        ranges:
        let
          sorted = lib.sort (a: b: a.start < b.start) ranges;
          step = acc: r: if acc == null || acc != r.start then null else r.start + r.len;
          end = lib.foldl' step 0 sorted;
        in
        end == 4294967295;
      autostartOn = hostSystem.extendModules {
        modules = [ { permafrost.host.autostart = true; } ];
      };

      # The text of the chain `egress`, which is last in the table.
      egress = lib.last (
        lib.splitString "chain egress {" guest.networking.nftables.tables.permafrost.content
      );
      tableText = c: c.networking.nftables.tables.permafrost.content;
      builderChain =
        c:
        lib.head (
          lib.splitString "chain netctl_only {" (lib.last (lib.splitString "chain builders {" (tableText c)))
        );
      withProfiles =
        profiles:
        (guestSystem.extendModules { modules = [ { permafrost.network.profiles = profiles; } ]; }).config;
      offline = withProfiles {
        offline = {
          title = "Offline";
          internet.enable = false;
        };
      };
      httpsOnly = withProfiles {
        https-only = {
          title = "HTTPS only";
          internet.tcpPorts = [ 443 ];
        };
      };
      egressRules = lib.filter (l: l != "" && !(lib.hasPrefix "type filter hook" l) && l != "}") (
        map lib.trim (lib.splitString "\n" egress)
      );
    in
    {
      checks = {
        vm-slots = import ../_checks/slots.nix {
          inherit pkgs;
          nixosModules = config.flake.modules.nixos;
        };

        # The id map of the workspaces share is one list, and both launch paths
        # carry it as it is: the runner as the flags of its one virtiofsd, the
        # fleet host as the extraArgs of the share. posixAcl has to be off for
        # the fleet share, or virtiofsd refuses to start.
        workspaces-flags =
          pkgs.runCommand "check-workspaces-flags"
            {
              fleet = evalCheck "workspaces-flags-fleet" [
                {
                  assertion = fleetShare != null;
                  message = "the fleet host has no ${slotLib.shareTag} share";
                }
                {
                  assertion = fleetShare != null && !fleetShare.posixAcl && !fleetShare.readOnly;
                  message = "the fleet share has posixAcl on, or is read-only";
                }
                {
                  assertion = fleetShare != null && fleetShare.extraArgs == virtiofsdArgs;
                  message = "the fleet share does not carry the flags of _lib/slots.nix";
                }
                {
                  assertion = fleetShare != null && fleetShare.source == slotCfg.workspaces.hostPath;
                  message = "the fleet share does not carry the host path of the guest options";
                }
                {
                  assertion = lib.length virtiofsdArgs == 20;
                  message = "the flags are not five rules for the uid and the gid";
                }
                {
                  assertion = guest.fileSystems.${slotLib.shareMount}.fsType == "virtiofs";
                  message = "the options of the share replaced its file system type";
                }
                {
                  assertion = lib.all (o: lib.elem o guest.fileSystems.${slotLib.shareMount}.options) [
                    "nosuid"
                    "nodev"
                  ];
                  message = "the share is not mounted nosuid,nodev";
                }
                {
                  # A link in a workspace has to work for its slot.
                  assertion = lib.all (mount: !(lib.elem "nosymfollow" guest.fileSystems.${mount}.options)) (
                    lib.filter (m: lib.hasPrefix "/home/slots/" m || m == slotLib.shareMount) (
                      lib.attrNames guest.fileSystems
                    )
                  );
                  message = "a mount of the workspaces has nosymfollow";
                }
                {
                  assertion = lib.all (
                    name:
                    guest.fileSystems."${slotCfg.homeRoot}/${name}/workspaces".device == "${slotLib.shareMount}/${name}"
                  ) (slotLib.names slotCfg);
                  message = "a slot does not have its own directory of the share";
                }
              ];
            }
            ''
              script=${self'.packages.permafrost}/bin/permafrost
              # One line starts the virtiofsd of the share, with all ten rules.
              line=$(grep -F -- '${slotLib.shareTag}.sock' "$script" | grep -F virtiofsd)
              test "$(printf '%s\n' "$line" | wc -l)" = 1
              test "$(grep -o -- '--translate-' "$script" | wc -l)" = 10
              ${lib.concatMapStringsSep "\n" (
                a: "printf '%s' \"$line\" | grep -qF -- ${lib.escapeShellArg a}"
              ) virtiofsdArgs}
              printf '%s' "$line" | grep -qF -- '--shared-dir "${slotCfg.workspaces.hostPath}"'
              touch $out
            '';

        # The id map covers every id once, on the guest side and on the host
        # side: no gap that passes an id through unchanged, no overlap that
        # virtiofsd would have to choose between. The flags are the same text
        # for the uid and the gid. scripts/mapping-smoke.sh is the run against a
        # real virtiofsd, and it needs sudo and /dev/kvm, so no flake check runs
        # it; this is the part of it that a pure evaluation can hold.
        workspaces-map-coverage = evalCheck "workspaces-map-coverage" [
          {
            assertion = tiles (guestRanges (rulesFor "--translate-uid"));
            message = "the guest uid rules leave a gap or overlap: ${builtins.toJSON (rulesFor "--translate-uid")}";
          }
          {
            assertion = tiles (hostRanges (rulesFor "--translate-uid"));
            message = "the host uid rules leave a gap or overlap: ${builtins.toJSON (rulesFor "--translate-uid")}";
          }
          {
            assertion = rulesFor "--translate-uid" == rulesFor "--translate-gid";
            message = "the uid and gid rules differ";
          }
          {
            # The slot ids map to host ids above the reader group, and the
            # reader group itself is below them, so it is squashed.
            assertion = lib.elem [
              "map"
              (toString (slotCfg.uidBase + 1))
              (toString (slotCfg.workspaces.hostIdBase + 1))
              (toString slotCfg.count)
            ] (rulesFor "--translate-uid");
            message = "the map rule is not the slot ids to the host ids";
          }
          {
            assertion = slotCfg.workspaces.hostIdBase + slotCfg.count < slotLib.hostIdMax;
            message = "the host ids of the slots reach the foreign range of systemd";
          }
        ];

        # The host module as a real host has it: what the VM check stands in for
        # with a copy. The mount of the reader and the tree are pinned here on
        # the real configuration.
        host-workspaces-config = evalCheck "host-workspaces-config" [
          {
            assertion =
              lib.all (point: host.fileSystems ? ${point}) readerMountPoints && readerMountPoints != [ ];
            message = "the host has no mount of the reader for a slot";
          }
          {
            assertion = !(host.fileSystems ? ${hostCfg.readerPath});
            message = "the reader has one mount for the whole tree; it must be one for each slot (a walk out of a slot directory must end at its mount)";
          }
          {
            assertion = lib.all (
              point:
              lib.all (o: lib.elem o host.fileSystems.${point}.options) [
                "bind"
                "ro"
                "nosymfollow"
                "nosuid"
                "nodev"
              ]
            ) readerMountPoints;
            message = "a reader mount lacks one of bind, ro, nosymfollow, nosuid, nodev";
          }
          {
            assertion = lib.all (
              n:
              let
                point = "${hostCfg.readerPath}/${slotLib.name hostCfg n}";
              in
              host.fileSystems.${point}.device == "${hostCfg.path}/${slotLib.name hostCfg n}"
              && host.fileSystems.${point}.fsType == "none"
            ) (lib.range 1 hostCfg.count);
            message = "a reader mount is not a bind of the directory of its slot";
          }
          {
            # The same function builds the mounts in the VM check, so the check
            # tests what the host has.
            assertion = lib.all (
              point: (slotLib.readerMount hostCfg).${point}.options == host.fileSystems.${point}.options
            ) readerMountPoints;
            message = "the VM check mounts other options than the host has";
          }
          {
            assertion = lib.elem "d ${hostCfg.readerPath} 0750 root ${toString hostCfg.hostIdBase} - -" host.systemd.tmpfiles.rules;
            message = "the reader directory has no tmpfiles line 0750 root:readerGroup";
          }
          {
            assertion = lib.elem "d ${hostCfg.path} 0750 root ${toString hostCfg.hostIdBase} - -" host.systemd.tmpfiles.rules;
            message = "the share directory has no tmpfiles line 0750 root:readerGroup";
          }
          {
            assertion = lib.all (
              n:
              lib.elem "d ${hostCfg.path}/${slotLib.name hostCfg n} 2750 ${toString (hostCfg.hostIdBase + n)} ${toString hostCfg.hostIdBase} - -" host.systemd.tmpfiles.rules
            ) (lib.range 1 hostCfg.count);
            message = "a slot directory has no tmpfiles line 2750 slot:readerGroup";
          }
          {
            # Not RemainAfterExit: a start of the reader runs the check again.
            assertion = !(host.systemd.services.permafrost-workspaces-ro-check.serviceConfig ? RemainAfterExit);
            message = "the ro-check unit stays active after one run";
          }
          {
            assertion = host.systemd.timers ? permafrost-workspaces-ro-check;
            message = "no timer runs the ro-check again";
          }
        ];

        # Confinement of the guest as the real guest has it.
        confinement-config = evalCheck "confinement-config" [
          {
            # Builds may reach the public ports that every profile allows, and
            # no more: one profile without internet takes them all away.
            assertion = lib.hasInfix "tcp dport { 80, 443 } accept" (builderChain guest);
            message = "the builders do not have public 80 and 443 with the default profile";
          }
          {
            assertion = !lib.hasInfix "@reserved4 tcp dport" (builderChain offline);
            message = "builds reach public ports although a profile has no internet";
          }
          {
            assertion =
              lib.hasInfix "@reserved4 tcp dport { 443 } accept" (builderChain httpsOnly)
              && !(lib.hasInfix "80" (builderChain httpsOnly));
            message = "builds reach more public ports than the narrowest profile";
          }
          {
            # The builders still have the internal list and the resolvers.
            assertion =
              lib.hasInfix "@internal4_ports accept" (builderChain offline)
              && lib.hasInfix "@resolvers4" (builderChain offline);
            message = "the builders lost the internal list or the resolvers";
          }
          {
            # An address that a NAT64 router turns into a LAN address is not
            # public. Every transition prefix is reserved.
            assertion = lib.all (p: lib.elem p guest.permafrost.network.reservedRanges.v6) [
              "::ffff:0:0/96"
              "64:ff9b::/96"
              "64:ff9b:1::/48"
              "2002::/16"
              "2001::/32"
            ];
            message = "an IPv6 transition prefix is not reserved";
          }
          {
            assertion =
              let
                g = guest.systemd.services.permafrost-egress-guard;
              in
              lib.elem "sshd.service" g.requiredBy
              && lib.elem "sshd.service" g.before
              && lib.elem "nftables.service" g.after
              && lib.elem "nftables.service" g.requires;
            message = "sshd does not wait for the egress guard, or the guard does not follow nftables";
          }
          {
            assertion =
              let
                r = guest.systemd.services.permafrost-netctl-restore;
              in
              lib.elem "nftables.service" r.after
              && lib.elem "nftables.service" r.partOf
              && r.unitConfig.ReloadPropagatedFrom == [ "nftables.service" ]
              && r.serviceConfig ? ExecReload;
            message = "a reload or restart of nftables does not restore the profiles";
          }
          {
            # The tailscaled socket is for root and the group tailscale: a slot
            # has no such group, and agent has it.
            assertion =
              guest.systemd.services.tailscaled.serviceConfig.RuntimeDirectoryMode == "0750"
              && lib.hasInfix "chgrp tailscale /run/tailscale" guest.systemd.services.tailscaled.serviceConfig.ExecStartPost
              && lib.elem "tailscale" guest.users.users.agent.extraGroups;
            message = "the tailscaled socket is open to every account";
          }
          {
            assertion = lib.all (n: guest.users.users.${n}.extraGroups == [ ]) (slotLib.names slotCfg);
            message = "a slot has a supplementary group";
          }
        ];

        # The host tree is made by a runner that is root, so every directory
        # goes through safe_dir first, and what is made is the directory and
        # nothing below it.
        runner-guard = pkgs.runCommand "check-runner-guard" { nativeBuildInputs = [ pkgs.gawk ]; } ''
          awk -v root=${lib.escapeShellArg hostPathText} -v want=${toString (slotCfg.count + 1)} '
            { sub(/^ +/, "") }
            index($0, "/bin/install -d ") && index($0, root) {
              installs++
              if (prev != "safe_dir " $NF) { print "install without safe_dir: " $0; bad = 1 }
            }
            index($0, "/bin/chmod 2750 ") {
              chmods++
              if (!index(prev, "/bin/install -d ") || prev !~ (" " $NF "$")) { print "chmod after no install: " $0; bad = 1 }
            }
            /(chown|chmod) -R/ { print "recursive: " $0; bad = 1 }
            { prev = $0 }
            END {
              if (installs != want || chmods != want - 1) { print "found " installs " installs and " chmods " chmods, expected " want " and " want - 1; bad = 1 }
              exit bad
            }
          ' ${self'.packages.permafrost}/bin/permafrost
          grep -q '^safe_dir() {' ${self'.packages.permafrost}/bin/permafrost
          touch $out
        '';

        # The guest and the host say the same about the share, whichever way
        # the host got its numbers: the defaults of the two option sets are one
        # block in _lib/slots.nix, and the fleet host takes the values of the
        # guest it evaluates.
        workspaces-ids-agree =
          let
            guestOpts = guestSystem.options.permafrost.slots;
            hostOpts = hostSystem.options.permafrost.host.workspaces;
            hostCfg = host.permafrost.host.workspaces;
          in
          evalCheck "workspaces-ids-agree" [
            {
              assertion = guestOpts.count.default == hostOpts.count.default;
              message = "the default count differs between the guest and the host";
            }
            {
              assertion = guestOpts.userPrefix.default == hostOpts.userPrefix.default;
              message = "the default userPrefix differs between the guest and the host";
            }
            {
              assertion = guestOpts.workspaces.hostPath.default == hostOpts.path.default;
              message = "the default host path differs between the guest and the host";
            }
            {
              assertion = guestOpts.workspaces.hostIdBase.default == hostOpts.hostIdBase.default;
              message = "the default hostIdBase differs between the guest and the host";
            }
            {
              assertion =
                hostCfg.count == slotCfg.count
                && hostCfg.userPrefix == slotCfg.userPrefix
                && hostCfg.path == slotCfg.workspaces.hostPath
                && hostCfg.hostIdBase == slotCfg.workspaces.hostIdBase;
              message = "the fleet host has other numbers than the guest it evaluates";
            }
            {
              assertion = host.users.groups.${hostCfg.readerGroup}.gid == slotLib.readerGid slotCfg;
              message = "the reader group is not the first id of the range";
            }
          ];

        # The autostart option: off by default, and on it wants the guest unit.
        autostart-option = evalCheck "autostart-option" [
          {
            assertion =
              !host.microvm.vms.permafrost.autostart
              && !(lib.elem "microvm@permafrost.service" host.systemd.targets.microvms.wants);
            message = "the guest starts at boot by default";
          }
          {
            assertion =
              autostartOn.config.microvm.vms.permafrost.autostart
              && lib.elem "microvm@permafrost.service" autostartOn.config.systemd.targets.microvms.wants;
            message = "permafrost.host.autostart does not make the host want the guest";
          }
          {
            assertion = host.warnings == [ ] && autostartOn.config.warnings == [ ];
            message = "the host evaluates with a warning";
          }
        ];

        # No setuid wrapper or daemon that could raise the rights of a slot. The
        # netctl helper is the one way to change a profile, and it needs neither.
        no-sudo = evalCheck "no-sudo" [
          {
            assertion = !guest.security.sudo.enable;
            message = "security.sudo is on in the guest";
          }
          {
            assertion = !guest.security.polkit.enable;
            message = "security.polkit is on in the guest";
          }
          {
            assertion = !(guest.security.wrappers ? sudo);
            message = "a sudo wrapper exists";
          }
        ];

        # The egress table and the netctl account as the real guest has them.
        egress-config = evalCheck "egress-config" [
          {
            assertion = guest.networking.nftables.enable && !guest.networking.nftables.flushRuleset;
            message = "nftables is off, or flushes the whole ruleset";
          }
          {
            assertion = guest.networking.nftables.checkRuleset;
            message = "the ruleset check is off";
          }
          {
            # The chain that every packet passes holds jumps only. A rule with a
            # verdict there would reach root and the daemons.
            assertion = lib.all (l: lib.hasInfix " jump " l) egressRules && egressRules != [ ];
            message = "the egress chain has a rule that is not a jump";
          }
          {
            assertion =
              lib.all (c: lib.hasInfix "chain ${c} {" guest.networking.nftables.tables.permafrost.content)
                [
                  "confined"
                  "builders"
                  "netctl_only"
                ];
            message = "a confined group has no chain";
          }
          {
            assertion = lib.hasInfix "meta skgid ${toString guest.ids.gids.nixbld} jump builders" egress;
            message = "the Nix build users are not confined";
          }
          {
            assertion = guest.users.users.netctl.extraGroups == [ ] && !guest.users.users.netctl.createHome;
            message = "netctl has a group or a home";
          }
          {
            assertion = guest.users.users.netctl.shell.shellPath == "/bin/permafrost-netctl-ssh";
            message = "the netctl login shell is not the wrapper";
          }
          {
            assertion = !(lib.elem "netctl" guest.nix.settings.allowed-users);
            message = "netctl may use the Nix daemon";
          }
          {
            assertion = lib.hasInfix "Match User netctl" guest.services.openssh.extraConfig;
            message = "sshd has no Match block for netctl";
          }
        ];
      };
    };
}
