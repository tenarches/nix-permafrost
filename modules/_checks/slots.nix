# VM check of the factory slot accounts (guest/slots.nix) next to adurable.
#
# Two nodes: `guest` carries the modules under test, `site` is the ssh client
# and signs the certificates. The CA is made here and is a test CA: nothing in
# it is a secret of any real system.
{ pkgs, nixosModules }:

let
  # One CA and one user key for every login the script tries.
  keys = pkgs.runCommand "slots-test-keys" { nativeBuildInputs = [ pkgs.openssh ]; } ''
    mkdir $out
    ssh-keygen -q -t ed25519 -N "" -C test-ca -f $out/ca
    ssh-keygen -q -t ed25519 -N "" -C test-user -f $out/user
  '';
in
pkgs.testers.runNixOSTest {
  name = "slots";

  nodes = {
    guest =
      { lib, ... }:
      {
        imports = [
          nixosModules.guest-slots
          nixosModules.guest-adurable
          nixosModules.guest-ssh-ca
        ];

        permafrost = {
          slots.count = 3;
          ssh.trustedUserCAKeys = "${keys}/ca.pub";
        };

        # What guest/base.nix sets and the node does not import.
        security.sudo.enable = false;
        security.polkit.enable = false;
        users = {
          mutableUsers = false;
          allowNoPasswordLogin = true;
        };
        services.openssh = {
          enable = true;
          settings = {
            PasswordAuthentication = false;
            KbdInteractiveAuthentication = false;
            PermitRootLogin = lib.mkForce "prohibit-password";
            AuthorizedKeysFile = "/etc/ssh/authorized_keys.d/%u .ssh/authorized_keys";
            # The script makes many logins that fail on purpose from one source.
            # With penalties on, sshd resets the later connections, and the
            # script would see a refusal that no rule of the guest caused.
            PerSourcePenalties = "no";
          };
          # A global line from a module that does not use mkAfter. It must stay
          # global, above the first Match block.
          extraConfig = "MaxAuthTries 3";
        };
      };

    site =
      { pkgs, ... }:
      {
        environment.systemPackages = [ pkgs.openssh ];
      };
  };

  testScript = ''
    SSH = (
        "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "
        "-o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10 "
    )


    def ssh(user, ident, cmd, stdin="/dev/null"):
        # ssh reads the stdin of the shell that the test driver talks to, so
        # every call names its own stdin.
        return f"{SSH} -i /root/id-{ident} {user}@guest '{cmd}' < {stdin}"


    start_all()
    guest.wait_for_unit("sshd.service")
    site.wait_for_unit("multi-user.target")

    # The CA key and the user key are copied to where ssh accepts their modes.
    site.succeed(
        "install -m 0600 ${keys}/ca /root/ca",
        "install -m 0600 ${keys}/user /root/id-bare",
        "install -m 0644 ${keys}/user.pub /root/id-bare.pub",
    )


    def certify(principal):
        # One identity file for each principal. ssh loads <identity>-cert.pub
        # by itself.
        site.succeed(
            f"install -m 0600 ${keys}/user /root/id-{principal}",
            f"install -m 0644 ${keys}/user.pub /root/id-{principal}.pub",
            f"ssh-keygen -q -s /root/ca -I {principal} -n {principal} "
            f"-V always:forever /root/id-{principal}.pub",
        )


    for p in ["f-slot1", "f-slot2", "f-slot3", "adurable"]:
        certify(p)

    with subtest("each slot logs in as itself with its own certificate"):
        for n in ["f-slot1", "f-slot2", "f-slot3"]:
            assert site.succeed(ssh(n, n, "id -un")).strip() == n
            assert site.succeed(ssh(n, n, "id -Gn")).strip() == n, "slot has extra groups"
        assert site.succeed(ssh("adurable", "adurable", "id -un")).strip() == "adurable"

    with subtest("a certificate opens its own account and no other"):
        site.fail(ssh("f-slot2", "f-slot1", "true"))
        site.fail(ssh("f-slot1", "f-slot2", "true"))
        site.fail(ssh("adurable", "f-slot1", "true"))
        site.fail(ssh("f-slot1", "adurable", "true"))
        site.fail(ssh("root", "f-slot1", "true"))
        site.fail(ssh("root", "adurable", "true"))
        site.fail(ssh("f-slot1", "bare", "true"))

    with subtest("a key in a slot home opens nothing"):
        site.succeed(
            ssh(
                "f-slot1",
                "f-slot1",
                "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys",
                stdin="/root/id-bare.pub",
            )
        )
        site.succeed(ssh("f-slot1", "f-slot1", "test -s ~/.ssh/authorized_keys"))
        site.fail(ssh("f-slot1", "bare", "true"))

    with subtest("umask and TMPDIR of the sessions"):
        for n in ["f-slot1", "f-slot2", "f-slot3"]:
            assert site.succeed(ssh(n, n, "umask")).strip() == "0027"
            assert site.succeed(ssh(n, n, "echo $TMPDIR")).strip() == f"/home/slots/{n}/tmp"
            site.succeed(ssh(n, n, "test -d $TMPDIR && touch $TMPDIR/x"))
        # The rule is for slot uids only. What an account outside the range gets
        # is not 0027.
        out = site.succeed(ssh("adurable", "adurable", "umask")).strip()
        assert out != "0027", out
        assert site.succeed(ssh("adurable", "adurable", "echo \"[$TMPDIR]\"")).strip() == "[]"
        # A process that does not pass through sshd starts under user@<uid>.
        out = site.succeed(
            ssh("f-slot1", "f-slot1", "systemd-run --user --wait --pipe sh -c umask")
        ).strip()
        assert out == "0027", out
        # A file a slot makes has group read and nothing for others.
        site.succeed(ssh("f-slot1", "f-slot1", "touch ~/f && mkdir ~/d"))
        assert guest.succeed("stat -c %a /home/slots/f-slot1/f").strip() == "640"
        assert guest.succeed("stat -c %a /home/slots/f-slot1/d").strip() == "750"

    with subtest("sshd settings per account"):
        def sshd_t(user):
            # sshd prints CamelCase keys. Compare in lower case, but keep the
            # value of TMPDIR as it is written.
            return guest.succeed(
                f"sshd -T -f /etc/ssh/sshd_config -C user={user},host=x,addr=1.1.1.1"
            ).lower()

        for n in ["f-slot1", "f-slot2", "f-slot3"]:
            out = sshd_t(n)
            assert "authorizedkeysfile none" in out, out
            assert f"setenv tmpdir=/home/slots/{n}/tmp" in out, out
            assert "allowtcpforwarding no" in out, out
            assert "allowagentforwarding no" in out, out
            assert "permituserrc no" in out, out
        out = sshd_t("adurable")
        assert "authorizedkeysfile none" in out and "setenv" not in out, out
        # The global line stayed global: every account sees it, the last slot too.
        for n in ["root", "agent", "adurable", "f-slot1", "f-slot3"]:
            assert "maxauthtries 3" in sshd_t(n), n
        assert "allowtcpforwarding no" not in sshd_t("root")

    with subtest("slots cannot read each other, adurable or agent"):
        site.succeed(ssh("f-slot1", "f-slot1", "echo x > ~/secret"))
        site.succeed(ssh("adurable", "adurable", "echo x > ~/secret"))
        assert guest.succeed("stat -c %a /home/slots").strip() == "711"
        for n in ["f-slot1", "f-slot2", "f-slot3"]:
            assert guest.succeed(f"stat -c %a /home/slots/{n}").strip() == "700"
        site.fail(ssh("f-slot2", "f-slot2", "cat /home/slots/f-slot1/secret"))
        site.fail(ssh("f-slot2", "f-slot2", "ls /home/slots/f-slot1"))
        site.fail(ssh("f-slot2", "f-slot2", "ls /home/slots/f-slot1/tmp"))
        site.fail(ssh("f-slot2", "f-slot2", "ls /home/slots/f-slot1/work"))
        site.fail(ssh("f-slot2", "f-slot2", "touch /home/slots/f-slot1/x"))
        # Not listable at the top either.
        site.fail(ssh("f-slot2", "f-slot2", "ls /home/slots"))
        # adurable and the slots are closed to each other, in both directions.
        site.fail(ssh("adurable", "adurable", "cat /home/slots/f-slot1/secret"))
        site.fail(ssh("adurable", "adurable", "ls /home/slots/f-slot1"))
        site.fail(ssh("f-slot1", "f-slot1", "cat /home/adurable/secret"))
        site.fail(ssh("f-slot1", "f-slot1", "ls /home/adurable"))
        # A slot has no way to the Nix daemon of root and no sudo.
        site.fail(ssh("f-slot1", "f-slot1", "type sudo"))
        site.succeed(ssh("f-slot1", "f-slot1", "grep -q '^CapEff:.0000000000000000$' /proc/self/status"))
  '';
}
