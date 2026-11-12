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
      autostartOn = hostSystem.extendModules {
        modules = [ { permafrost.host.autostart = true; } ];
      };

      # The text of the chain `egress`, which is last in the table.
      egress = lib.last (
        lib.splitString "chain egress {" guest.networking.nftables.tables.permafrost.content
      );
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
                  assertion = lib.length virtiofsdArgs == 12;
                  message = "the flags are not six rules for the uid and the gid";
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
              # One line starts the virtiofsd of the share, with all six rules.
              line=$(grep -F -- '${slotLib.shareTag}.sock' "$script" | grep -F virtiofsd)
              test "$(printf '%s\n' "$line" | wc -l)" = 1
              test "$(grep -o -- '--translate-' "$script" | wc -l)" = 6
              ${lib.concatMapStringsSep "\n" (
                a: "printf '%s' \"$line\" | grep -qF -- ${lib.escapeShellArg a}"
              ) virtiofsdArgs}
              printf '%s' "$line" | grep -qF -- '--shared-dir "${slotCfg.workspaces.hostPath}"'
              touch $out
            '';

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
