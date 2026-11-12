{ config, lib, ... }:
let
  guest = config.flake.nixosConfigurations.permafrost.config;
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
    { pkgs, ... }:
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
