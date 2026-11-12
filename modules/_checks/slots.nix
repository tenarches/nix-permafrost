# VM check of the factory slot accounts (guest/slots.nix) next to adurable, of
# the egress table (guest/network-egress.nix), of netctl (guest/netctl.nix) and
# of the workspaces share, from both ends: the bind mounts in the guest, and the
# read-only view of the host module (host/workspaces.nix) on `lan`.
#
# Three nodes: `guest` carries the modules under test. `site` is the ssh client,
# signs the certificates, and counts as the internet: 203.0.113.0/24 is
# TEST-NET-3, which the egress table does not list as a reserved range. `lan`
# is a host on the second network, 10.99.0.0/24, which the table treats as
# private. The CA is made here and is a test CA: nothing in it is a secret of
# any real system.
{ pkgs, nixosModules }:

let
  inherit (pkgs) lib;

  guestIp = "203.0.113.2";
  guestIp6 = "2001:db8:1::2";
  siteIp = "203.0.113.10";
  siteIp6 = "2001:db8:1::10";
  lanIp = "10.99.0.10";
  lanIp6 = "fd00:99::10";
  internalIp = "10.99.0.20";

  slotLib = import ../_lib/slots.nix;
  slotCount = 3;
  hostIdBase = slotLib.defaults.hostIdBase;

  # The function that guards the host tree in the runner, as the runner has it.
  safeDir = pkgs.writeText "safe-dir.sh" (slotLib.safeDir pkgs.coreutils);

  # What a client connects to. One line out: `ok` or `err <errno> <seconds>`.
  probe = pkgs.writers.writePython3Bin "probe" { flakeIgnore = [ "E501" ]; } ''
    import errno
    import socket
    import sys
    import time

    host, port = sys.argv[1], int(sys.argv[2])
    udp = len(sys.argv) > 3 and sys.argv[3] == "udp"
    family = socket.AF_INET6 if ":" in host else socket.AF_INET
    start = time.monotonic()
    try:
        s = socket.socket(family, socket.SOCK_DGRAM if udp else socket.SOCK_STREAM)
        s.settimeout(3)
        s.connect((host, port))
        if udp:
            s.send(b"ping")
            s.recv(16)
        print("ok")
    except OSError as e:
        print("err", errno.errorcode.get(e.errno, e.errno), round(time.monotonic() - start, 2))
        sys.exit(1)
  '';

  # Holds one TCP connection open until the peer or the kernel ends it.
  hold = pkgs.writers.writePython3Bin "hold" { flakeIgnore = [ "E501" ]; } ''
    import errno
    import socket
    import sys

    s = socket.create_connection((sys.argv[1], int(sys.argv[2])), timeout=5)
    s.sendall(b"GET / HTTP/1.1\r\nHost: x\r\n")
    print("up", flush=True)
    s.settimeout(40)
    try:
        data = s.recv(16)
        print("eof" if not data else "data")
    except OSError as e:
        print("closed", errno.errorcode.get(e.errno, e.errno))
  '';

  # The resolver of the check, and a second host on port 53: both answer every
  # datagram with itself, so only the table can make one of them fail.
  udpEcho = pkgs.writers.writePython3Bin "udp-echo" { flakeIgnore = [ "E501" ]; } ''
    import select
    import socket

    # One socket for each address: an answer must leave from the address it was
    # asked on, or a connected client drops it.
    socks = []
    for addr in ("${lanIp}", "${internalIp}"):
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.bind((addr, 53))
        socks.append(s)
    while True:
        for s in select.select(socks, [], [])[0]:
            data, peer = s.recvfrom(512)
            s.sendto(data, peer)
  '';

  webRoot = pkgs.writeTextDir "x" "hello\n";

  # A listener on every address of the node, one service for each port.
  listeners =
    ports:
    lib.listToAttrs (
      map (
        port:
        lib.nameValuePair "http-${toString port}" {
          wantedBy = [ "multi-user.target" ];
          after = [ "network.target" ];
          serviceConfig = {
            ExecStart = "${pkgs.python3}/bin/python3 -m http.server ${toString port} --bind :: --directory ${webRoot}";
            Restart = "always";
            RestartSec = 1;
          };
        }
      ) ports
    );

  # A fixed-output derivation that fetches one URL. The hash is that of the
  # body the listeners serve, so a fetch that gets through also succeeds. The
  # output path of a fixed-output derivation follows its name and hash and not
  # its builder, so each fetch has a name of its own: a second fetch would
  # otherwise find the output of the first in the store and never run.
  fod =
    name: url:
    pkgs.writeText "fod.nix" ''
      # storePath puts the two programs in the inputs of the derivation. A plain
      # string would not, and the sandbox would not have them.
      let
        bash = builtins.storePath "${pkgs.bash}";
        curl = builtins.storePath "${pkgs.curl}";
      in
      derivation {
        name = "fetch-${name}";
        system = "${pkgs.stdenv.hostPlatform.system}";
        builder = "''${bash}/bin/bash";
        args = [ "-c" "''${curl}/bin/curl -sS --max-time 8 -o $out ${url}" ];
        outputHashMode = "flat";
        outputHashAlgo = "sha256";
        outputHash = builtins.hashString "sha256" "hello\n";
      }
    '';

  address = a: {
    address = a;
    prefixLength = 24;
  };
  address6 = a: {
    address = a;
    prefixLength = 64;
  };

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
      {
        config,
        lib,
        utils,
        ...
      }:
      {
        imports = [
          nixosModules.guest-slots
          nixosModules.guest-adurable
          nixosModules.guest-ssh-ca
          nixosModules.guest-network-egress
          nixosModules.guest-netctl
        ];

        virtualisation = {
          vlans = [
            1
            2
          ];
          memorySize = 1536;
        };

        # The test driver numbers the interfaces itself, so the addresses are
        # forced to what the script says.
        networking = {
          useDHCP = false;
          interfaces = {
            eth1 = {
              ipv4.addresses = lib.mkForce [ (address guestIp) ];
              ipv6.addresses = lib.mkForce [ (address6 guestIp6) ];
            };
            eth2 = {
              ipv4.addresses = lib.mkForce [ (address "10.99.0.2") ];
              ipv6.addresses = lib.mkForce [ (address6 "fd00:99::2") ];
            };
          };
          # A listener of a slot that the site connects to: the answer packets
          # of that connection must pass the table.
          firewall.allowedTCPPorts = [ 7004 ];
        };
        services.resolved.enable = true;
        # Slots may listen on 80 and 443 in this node, so that the listeners the
        # script starts are on ports that the internet rule opens.
        boot.kernel.sysctl."net.ipv4.ip_unprivileged_port_start" = 0;

        # Nothing to fetch from a cache in this network.
        nix.settings.substituters = lib.mkForce [ ];

        # Stands for the virtiofs share. A tmpfs, so the bind mounts and the
        # modes are the real ones; the id map is not tested here (a tmpfs has no
        # virtiofsd), scripts/mapping-smoke.sh does that. The directories are
        # made before the bind mounts, as the host makes them before the guest
        # starts, with the owner and group that the guest sees there: the slot,
        # and the group of the reader.
        #
        # The nodes of a VM check replace `fileSystems` with
        # `virtualisation.fileSystems`, so the mounts of the module are put
        # there by the same function that the module uses.
        virtualisation.fileSystems = lib.mkMerge [
          (slotLib.workspaceMounts config.permafrost.slots)
          {
            ${slotLib.shareMount} = {
              device = "tmpfs";
              fsType = "tmpfs";
              options = [ "mode=0755" ];
            };
          }
        ];
        systemd.services.workspaces-standin = {
          wantedBy = [ "local-fs.target" ];
          before = [
            "local-fs.target"
          ]
          ++ map (n: "${utils.escapeSystemdPath "/home/slots/f-slot${toString n}/workspaces"}.mount") (
            lib.range 1 slotCount
          );
          unitConfig = {
            DefaultDependencies = false;
            RequiresMountsFor = slotLib.shareMount;
          };
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = lib.concatMapStrings (n: ''
            install -d -m 2750 -o ${toString (2000 + n)} -g ${toString hostIdBase} ${slotLib.shareMount}/f-slot${toString n}
          '') (lib.range 1 slotCount);
        };

        permafrost = {
          slots.count = slotCount;
          ssh.trustedUserCAKeys = "${keys}/ca.pub";
          network = {
            resolvers = [ internalIp ];
            internal.svc = {
              addresses = [ internalIp ];
              tcpPorts = [ 80 ];
            };
            profiles.lan-test = {
              title = "LAN test";
              lan = [
                {
                  address = lanIp;
                  ports = [ 8080 ];
                }
              ];
            };
          };
        };

        environment.systemPackages = [
          probe
          hold
          pkgs.socat
          pkgs.curl
          pkgs.bash
          pkgs.python3
        ];

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
            # And ten logins at once for the concurrency test.
            MaxStartups = "100:30:200";
          };
          # A global line from a module that does not use mkAfter. It must stay
          # global, above the first Match block.
          extraConfig = "MaxAuthTries 3";
        };
      };

    site =
      { lib, pkgs, ... }:
      {
        virtualisation.vlans = [ 1 ];
        networking = {
          useDHCP = false;
          firewall.enable = false;
          interfaces.eth1 = {
            ipv4.addresses = lib.mkForce [ (address siteIp) ];
            ipv6.addresses = lib.mkForce [ (address6 siteIp6) ];
          };
        };
        environment.systemPackages = [
          pkgs.openssh
          pkgs.curl
          pkgs.python3
        ];
        systemd.services = listeners [
          80
          443
          8080
        ];
      };

    lan =
      {
        config,
        lib,
        pkgs,
        ...
      }:
      {
        # The host of the workspaces: the module of a real host, with the
        # accounts that the tests act as.
        imports = [ nixosModules.host-workspaces ];
        permafrost.host.workspaces.count = slotCount;
        # The nodes of a VM check replace `fileSystems`, so the read-only view
        # is put in `virtualisation.fileSystems` by the function of the module.
        virtualisation.fileSystems = slotLib.readerMount config.permafrost.host.workspaces;
        users.users = {
          outsider.isNormalUser = true;
          reader = {
            isNormalUser = true;
            extraGroups = [ "permafrost-ws" ];
          };
        };

        virtualisation.vlans = [ 2 ];
        networking = {
          useDHCP = false;
          firewall.enable = false;
          interfaces.eth1 = {
            ipv4.addresses = lib.mkForce [
              (address lanIp)
              (address internalIp)
            ];
            ipv6.addresses = lib.mkForce [ (address6 lanIp6) ];
          };
        };
        systemd.services =
          listeners [
            80
            8080
          ]
          // {
            # The unit of a reader as stage 6 writes it: it requires the check of
            # the mount and starts after it. The script asks whether that holds.
            reader-stub = {
              requires = [ "permafrost-workspaces-ro-check.service" ];
              after = [ "permafrost-workspaces-ro-check.service" ];
              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
                ExecStart = "${pkgs.coreutils}/bin/true";
              };
            };

            udp-echo = {
              wantedBy = [ "multi-user.target" ];
              after = [ "network-addresses-eth1.service" ];
              serviceConfig = {
                ExecStart = "${udpEcho}/bin/udp-echo";
                Restart = "always";
                RestartSec = 1;
              };
            };
          };
      };
  };

  testScript = ''
    import json
    import shlex
    from datetime import timedelta

    GUEST = "${guestIp}"
    guestIp6 = "${guestIp6}"
    siteIp = "${siteIp}"
    siteIp6 = "${siteIp6}"
    lanIp = "${lanIp}"
    lanIp6 = "${lanIp6}"
    internalIp = "${internalIp}"
    SSH = (
        "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "
        "-o IdentitiesOnly=yes -o BatchMode=yes -o LogLevel=ERROR "
    )


    def ssh(user, ident, cmd, stdin="/dev/null", opts="", timeout=10):
        # ssh reads the stdin of the shell that the test driver talks to, so
        # every call names its own stdin.
        return (
            f"{SSH} {opts} -o ConnectTimeout={timeout} -i /root/id-{ident} "
            f"{user}@{GUEST} {shlex.quote(cmd)} < {stdin}"
        )


    def denied(who, cmd, path):
        # A refusal of the file system, not of the login: the command ran, and
        # its own message names the path. A failed login is status 255, and
        # says `Permission denied (publickey)` without the path.
        status, out = site.execute(ssh(who, who, cmd + " 2>&1"))
        assert status not in (0, 255) and "Permission denied" in out and path in out, (who, cmd, status, out)


    start_all()
    guest.wait_for_unit("sshd.service")
    guest.wait_for_unit("nftables.service")
    site.wait_for_unit("multi-user.target")
    lan.wait_for_unit("multi-user.target")
    for m in [guest, site, lan]:
        # An address is usable once duplicate detection has ended.
        m.wait_until_succeeds("test -z \"$(ip -6 addr show tentative)\"")
    site.wait_for_open_port(80)
    site.wait_for_open_port(8080)
    lan.wait_for_open_port(8080)
    lan.wait_for_unit("udp-echo.service")

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


    for p in ["f-slot1", "f-slot2", "f-slot3", "adurable", "netctl"]:
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
        site.fail(ssh("netctl", "f-slot1", "list"))

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
        # The netctl account has the one command and no forwarding.
        out = sshd_t("netctl")
        assert "forcecommand /run/current-system/sw/bin/permafrost-netctl-ssh" in out, out
        for line in [
            "permitopen none",
            "permitlisten none",
            "permittty no",
            "allowtcpforwarding no",
            "allowstreamlocalforwarding no",
            "x11forwarding no",
            "permittunnel no",
        ]:
            assert line in out, (line, out)
        # The global line stayed global: every account sees it, the last slot too.
        for n in ["root", "agent", "adurable", "netctl", "f-slot1", "f-slot3"]:
            assert "maxauthtries 3" in sshd_t(n), n
        assert "allowtcpforwarding no" not in sshd_t("root")

    with subtest("slots cannot read each other, adurable or agent"):
        site.succeed(ssh("f-slot1", "f-slot1", "echo x > ~/secret"))
        site.succeed(ssh("adurable", "adurable", "echo x > ~/secret"))
        assert guest.succeed("stat -c %a /home/slots").strip() == "711"
        for n in ["f-slot1", "f-slot2", "f-slot3"]:
            assert guest.succeed(f"stat -c %a /home/slots/{n}").strip() == "700"
        # The owner does the same things to the same paths: what the others are
        # refused is there, and the login works.
        site.succeed(ssh("f-slot1", "f-slot1", "cat /home/slots/f-slot1/secret"))
        for d in ["", "/tmp", "/work"]:
            site.succeed(ssh("f-slot1", "f-slot1", f"ls /home/slots/f-slot1{d}"))
        site.succeed(ssh("f-slot1", "f-slot1", "touch /home/slots/f-slot1/x && rm /home/slots/f-slot1/x"))
        site.succeed(ssh("adurable", "adurable", "cat /home/adurable/secret && ls /home/adurable"))
        denied("f-slot2", "cat /home/slots/f-slot1/secret", "/home/slots/f-slot1/secret")
        denied("f-slot2", "ls /home/slots/f-slot1", "/home/slots/f-slot1")
        denied("f-slot2", "ls /home/slots/f-slot1/tmp", "/home/slots/f-slot1/tmp")
        denied("f-slot2", "ls /home/slots/f-slot1/work", "/home/slots/f-slot1/work")
        denied("f-slot2", "touch /home/slots/f-slot1/x", "/home/slots/f-slot1/x")
        # Not listable at the top either.
        denied("f-slot2", "ls /home/slots", "/home/slots")
        # adurable and the slots are closed to each other, in both directions.
        denied("adurable", "cat /home/slots/f-slot1/secret", "/home/slots/f-slot1/secret")
        denied("adurable", "ls /home/slots/f-slot1", "/home/slots/f-slot1")
        denied("f-slot1", "cat /home/adurable/secret", "/home/adurable/secret")
        denied("f-slot1", "ls /home/adurable", "/home/adurable")
        # A slot has no way to the Nix daemon of root and no sudo.
        site.fail(ssh("f-slot1", "f-slot1", "type sudo"))
        site.succeed(ssh("f-slot1", "f-slot1", "grep -q '^CapEff:.0000000000000000$' /proc/self/status"))

    with subtest("each slot has its own workspaces, behind a directory that only root enters"):
        assert guest.succeed("stat -c '%a %u %g' ${slotLib.shareRoot}").strip() == "700 0 0"
        guest.succeed("systemctl is-active permafrost-factory-guard.service")
        for n in ["f-slot1", "f-slot2", "f-slot3"]:
            opts = guest.succeed(f"findmnt -n -o OPTIONS /home/slots/{n}/workspaces").strip().splitlines()[-1]
            assert "nosuid" in opts and "nodev" in opts, opts
            # A link in a workspace has to work for its slot: no nosymfollow.
            assert "nosymfollow" not in opts, opts
        # The directory shows the owner and group that the host gives it.
        assert guest.succeed("stat -c '%u %g %a' /home/slots/f-slot1/workspaces").strip() == "2001 ${toString hostIdBase} 2750"
        site.succeed(
            ssh(
                "f-slot1",
                "f-slot1",
                "cd ~/workspaces && mkdir -p repo/.bin && echo mine > repo/file && ln -s file repo/link "
                "&& printf '#!/bin/sh\\necho ran\\n' > repo/tool && chmod +x repo/tool && ln -s ../tool repo/.bin/x",
            )
        )
        assert site.succeed(ssh("f-slot1", "f-slot1", "cat ~/workspaces/repo/link")).strip() == "mine"
        assert site.succeed(ssh("f-slot1", "f-slot1", "~/workspaces/repo/.bin/x")).strip() == "ran"
        # What the slot makes gets the mode of its umask and the group of the
        # setgid directory, which is what the host reader needs.
        assert guest.succeed("stat -c '%a %g' /home/slots/f-slot1/workspaces/repo/file").strip() == "640 ${toString hostIdBase}"
        site.succeed(ssh("f-slot2", "f-slot2", "echo two > ~/workspaces/two"))
        # Nobody else gets in: not a peer slot, not adurable, not even the slot
        # itself above its own home.
        # Controls first: root reads the files through the share, and the owner
        # through the home, by the absolute paths that the others are refused.
        guest.succeed("cat ${slotLib.shareMount}/f-slot1/repo/file")
        site.succeed(ssh("f-slot1", "f-slot1", "cat /home/slots/f-slot1/workspaces/repo/file && ls /home/slots/f-slot1/workspaces"))
        site.succeed(ssh("f-slot2", "f-slot2", "cat /home/slots/f-slot2/workspaces/two"))
        for who in ["f-slot2", "adurable"]:
            denied(who, "cat /home/slots/f-slot1/workspaces/repo/file", "/home/slots/f-slot1")
            denied(who, "ls /home/slots/f-slot1/workspaces", "/home/slots/f-slot1")
            denied(who, "ls ${slotLib.shareRoot}", "${slotLib.shareRoot}")
            denied(who, "ls ${slotLib.shareMount}", "${slotLib.shareMount}")
            denied(who, "cat ${slotLib.shareMount}/f-slot1/repo/file", "${slotLib.shareMount}")
        denied("f-slot1", "ls ${slotLib.shareRoot}", "${slotLib.shareRoot}")
        denied("f-slot1", "cat /home/slots/f-slot2/workspaces/two", "/home/slots/f-slot2")
        denied("f-slot1", "cat ${slotLib.shareMount}/f-slot2/two", "${slotLib.shareMount}")
        # A slot that opens its whole tree to everybody still hides it: the
        # directory, the repository and the file are all readable by others
        # now, so what stops slot 2 is the 0700 home above the bind mount and
        # the 0700 directory above the share, and nothing in the tree.
        site.succeed(ssh("f-slot1", "f-slot1", "chmod -R 777 ~/workspaces && chmod 644 ~/workspaces/repo/file"))
        assert guest.succeed("stat -c %a /home/slots/f-slot1/workspaces /home/slots/f-slot1/workspaces/repo /home/slots/f-slot1/workspaces/repo/file").split() == ["777", "777", "644"]
        denied("f-slot2", "cat /home/slots/f-slot1/workspaces/repo/file", "/home/slots/f-slot1")
        denied("f-slot2", "cat ${slotLib.shareMount}/f-slot1/repo/file", "${slotLib.shareMount}")

    # --- Network access ------------------------------------------------------

    # What a refusal looks like to the client: see the reject rules in
    # guest/network-egress.nix. A UDP send is refused with EPERM when the verdict
    # reaches the sender first, and with ECONNREFUSED when the ICMP error does.
    REFUSED = {"v4tcp": ("EHOSTUNREACH",), "v6tcp": ("ECONNREFUSED",), "udp": ("EPERM", "ECONNREFUSED")}


    def reaches(slot, host, port, proto="tcp"):
        status, out = site.execute(ssh(slot, slot, f"probe {host} {port} {proto}"))
        assert status == 0 and out.strip() == "ok", (slot, host, port, proto, status, out)


    def rejected(slot, host, port, proto="tcp"):
        # A refusal comes back at once as an ICMP error, not as a timeout.
        status, out = site.execute(ssh(slot, slot, f"probe {host} {port} {proto}"))
        parts = out.split()
        assert status != 0 and parts[:1] == ["err"], (slot, host, port, proto, status, out)
        kind = "udp" if proto == "udp" else ("v6tcp" if ":" in host else "v4tcp")
        assert parts[1] in REFUSED[kind] and float(parts[2]) < 1.0, (slot, host, port, proto, out)


    def members(setname):
        out = json.loads(guest.succeed(f"nft -nnn -j list set inet permafrost {setname}"))
        for item in out["nftables"]:
            if "set" in item:
                return sorted(int(e) for e in item["set"].get("elem", []))
        raise AssertionError(out)


    def table():
        return guest.succeed("nft list table inet permafrost")


    with subtest("a slot reaches the internet on its ports and nothing else"):
        for host in [siteIp, siteIp6]:
            for port in [80, 443]:
                reaches("f-slot1", host, port)
            rejected("f-slot1", host, 8080)
        # Private ranges, v4 and v6.
        for port in [80, 8080]:
            rejected("f-slot1", lanIp, port)
            rejected("f-slot1", lanIp6, port)
        # The internal list: its host and its port, in every profile.
        reaches("f-slot1", internalIp, 80)
        rejected("f-slot1", internalIp, 8080)
        # The declared resolver, and no other host on port 53.
        reaches("f-slot1", internalIp, 53, "udp")
        rejected("f-slot1", lanIp, 53, "udp")
        # The resolved stub on loopback is the one local address a slot may use.
        reaches("f-slot1", "127.0.0.53", 53)

    with subtest("a slot cannot reach the guest itself or another slot"):
        site.succeed(ssh("f-slot2", "f-slot2", "nohup python3 -m http.server 7002 --bind 127.0.0.1 >/dev/null 2>&1 &"))
        site.succeed(ssh("adurable", "adurable", "nohup python3 -m http.server 7003 --bind 127.0.0.1 >/dev/null 2>&1 &"))
        guest.wait_until_succeeds("probe 127.0.0.1 7002 && probe 127.0.0.1 7003", timeout=60)
        # adurable is not filtered: it reaches the listener of slot 2 and its own.
        site.succeed(ssh("adurable", "adurable", "probe 127.0.0.1 7002 && probe 127.0.0.1 7003"))
        rejected("f-slot1", "127.0.0.1", 7002)
        rejected("f-slot1", "127.0.0.1", 7003)
        # A slot does not reach its own listener on loopback either.
        rejected("f-slot2", "127.0.0.1", 7002)
        # The addresses of the guest are public as far as the ranges go, and
        # ports 80 and 443 are open to every address that is not the guest. Only
        # the rule for local addresses stops these: a listener of slot 2 and one
        # of adurable, on every address of the guest.
        site.succeed(ssh("f-slot2", "f-slot2", "nohup python3 -m http.server 80 --bind :: >/dev/null 2>&1 &"))
        site.succeed(ssh("adurable", "adurable", "nohup python3 -m http.server 443 --bind :: >/dev/null 2>&1 &"))
        guest.wait_until_succeeds("probe 127.0.0.1 80 && probe 127.0.0.1 443", timeout=60)
        for addr in [GUEST, guestIp6, "10.99.0.2", "127.0.0.1", "::1"]:
            for port in [80, 443]:
                rejected("f-slot1", addr, port)
        rejected("f-slot2", GUEST, 80)
        # A listener of a slot still answers a client from outside.
        site.succeed(ssh("f-slot1", "f-slot1", "nohup python3 -m http.server 7004 --bind 0.0.0.0 >/dev/null 2>&1 &"))
        site.wait_until_succeeds(f"curl -s -o /dev/null --max-time 3 http://{GUEST}:7004/", timeout=60)

    with subtest("a slot cannot read or change the rules"):
        site.fail(ssh("f-slot1", "f-slot1", "nft list ruleset"))
        site.fail(ssh("f-slot1", "f-slot1", "nft list table inet permafrost"))
        site.fail(ssh("f-slot1", "f-slot1", "nft add element inet permafrost uids_lan_test { 2001 }"))
        assert 2001 not in members("uids_lan_test")

    with subtest("accounts outside the slots are not filtered"):
        for host, port in [(siteIp, 8080), (lanIp, 80), (lanIp, 8080)]:
            site.succeed(ssh("adurable", "adurable", f"probe {host} {port}"))
            guest.succeed(f"probe {host} {port}")

    with subtest("builds are confined: fixed-output fetches reach public 80 and 443 only"):
        nix_files = {
            "site80": "${fod "site80" "http://${siteIp}:80/x"}",
            "site8080": "${fod "site8080" "http://${siteIp}:8080/x"}",
            "lan80": "${fod "lan80" "http://${lanIp}:80/x"}",
            "internal80": "${fod "internal80" "http://${internalIp}:80/x"}",
        }
        build = lambda slot, key: ssh(slot, slot, f"nix-build --no-out-link {nix_files[key]}")
        site.succeed(build("f-slot1", "site80"))
        site.fail(build("f-slot1", "site8080"))
        site.fail(build("f-slot1", "lan80"))
        site.succeed(build("f-slot1", "internal80"))

    with subtest("vsock and tailscale are recorded, not claimed"):
        # AF_VSOCK to the host is open to a slot (documented). Nothing listens in
        # this node, so the connect is refused or times out. No claim of a block.
        status, out = site.execute(
            ssh(
                "f-slot1",
                "f-slot1",
                "python3 -c 'import socket; s=socket.socket(socket.AF_VSOCK); s.settimeout(2); s.connect((2,9999))'",
            )
        )
        print("vsock connect from a slot, status", status, out)

    # --- netctl --------------------------------------------------------------


    def netctl(cmd):
        return site.execute(ssh("netctl", "netctl", cmd))


    with subtest("a profile change takes effect without a restart"):
        status, out = netctl("list")
        assert status == 0 and out.strip() == "ok list default=internet-only profiles=internet-only,lan-test", out
        status, out = netctl("get f-slot1")
        assert status == 0 and out.strip() == "ok get slot=f-slot1 uid=2001 profile=internet-only", out
        status, out = netctl("set f-slot1 lan-test")
        assert status == 0 and out.startswith("ok set slot=f-slot1 uid=2001 from=internet-only to=lan-test killed="), out
        assert len(out.strip().splitlines()) == 1
        assert netctl("get f-slot1")[1].strip() == "ok get slot=f-slot1 uid=2001 profile=lan-test"
        assert members("uids_lan_test") == [2001]
        assert 2001 not in members("uids_internet_only")
        reaches("f-slot1", lanIp, 8080)
        rejected("f-slot1", lanIp, 80)
        # Per slot: slot 2 did not move.
        rejected("f-slot2", lanIp, 8080)
        # The internet and the internal list are still there on the new profile.
        reaches("f-slot1", siteIp, 80)
        reaches("f-slot1", internalIp, 80)
        # An account outside the slots is the same before and after.
        site.succeed(ssh("adurable", "adurable", f"probe {siteIp} 8080"))
        # The same profile again changes nothing.
        status, out = netctl("set f-slot1 lan-test")
        assert status == 0 and out.strip() == "ok set slot=f-slot1 uid=2001 profile=lan-test unchanged", out
        # A fixed-output fetch from the LAN still fails for a slot on the LAN profile.
        site.fail(ssh("f-slot1", "f-slot1", "nix-build --no-out-link ${fod "lan8080" "http://${lanIp}:8080/x"}"))

    with subtest("a change of profile closes the open connections of the slot"):
        site.execute("rm -f /tmp/hold.out; (" + ssh("f-slot1", "f-slot1", f"hold {lanIp} 8080") + " > /tmp/hold.out 2>&1 &)")
        site.wait_until_succeeds("grep -q '^up' /tmp/hold.out", timeout=60)
        guest.wait_until_succeeds(f"ss -tn state established dst {lanIp}:8080 | grep -q {lanIp}", timeout=60)
        status, out = netctl("set f-slot1 internet-only")
        assert status == 0 and "from=lan-test to=internet-only killed=1" in out, out
        site.wait_until_succeeds("grep -q '^closed' /tmp/hold.out", timeout=5)
        assert 2001 in members("uids_internet_only")
        rejected("f-slot1", lanIp, 8080)
        journal = guest.succeed("journalctl -t permafrost-netctl --no-pager")
        assert "netctl set slot=f-slot1 uid=2001 from=lan-test to=internet-only killed=1" in journal, journal
        assert "netctl-ssh peer=${siteIp} accepted" in journal, journal

    with subtest("a reload or a restart of nftables keeps the profile of every slot"):
        assert netctl("set f-slot2 lan-test")[0] == 0
        assert members("uids_lan_test") == [2002]
        reaches("f-slot2", lanIp, 8080)
        # The reload deletes the table and loads it again. Without the restore
        # unit, every slot would be on the default profile after it.
        # The reload of the restore unit is queued by the reload of nftables and
        # is not waited for by `systemctl reload`, so the script waits for the
        # result and not for the unit.
        def until(setname, uids):
            retry(lambda _: members(setname) == uids, timeout=timedelta(seconds=30))

        for how in ["reload", "restart"]:
            guest.succeed(f"systemctl {how} nftables")
            until("uids_lan_test", [2002])
            assert members("uids_lan_test") == [2002], how
            assert members("uids_internet_only") == [2001, 2003], how
            reaches("f-slot2", lanIp, 8080)
            rejected("f-slot1", lanIp, 8080)
        journal = guest.succeed("journalctl -t permafrost-netctl --no-pager")
        assert "netctl restore slot=f-slot2 uid=2002 to=lan-test" in journal, journal
        # The restore is the helper's `restore`: no input, no other change.
        assert netctl("restore")[1].strip() == "ok restore unchanged"
        assert netctl("set f-slot2 internet-only")[0] == 0
        guest.succeed("systemctl reload nftables")
        # Nothing is recorded to restore but the default profile for slot 2.
        until("uids_internet_only", [2001, 2002, 2003])
        assert members("uids_lan_test") == []
        assert members("uids_internet_only") == [2001, 2002, 2003]

    with subtest("the helper refuses what is outside the grammar and changes nothing"):
        cases = [
            ("set f-slot1 nope", 4),
            ("set f-slot9 lan-test", 3),
            ("set root lan-test", 3),
            ("get adurable", 3),
            ("get f-slot09", 3),
            ("set f-slot1 lan-test 10.99.0.10", 2),
            ("set f-slot1 10.99.0.10:8080", 2),
            ("set f-slot1 lan-test; id", 2),
            ("set f-slot1 lan-test\nset f-slot2 lan-test", 2),
            ("set  f-slot1 lan-test", 2),
            ("set f-slot1 lan-test ", 2),
            ("set f-slot1 " + "a" * 5000, 2),
            ("nft list ruleset", 2),
            ("id", 2),
            ("", 2),
        ]
        for cmd, code in cases:
            before = table()
            status, out = netctl(cmd)
            assert status == code, (cmd[:40], code, status, out)
            assert len(out.strip().splitlines()) == 1 and out.startswith("err "), (cmd[:40], out)
            assert table() == before, cmd[:40]
        # The helper checks the grammar again when the wrapper is bypassed.
        for line, reply in [
            ("set f-slot1 nope\n", "err 4 profile"),
            ("set f-slot1 lan-test; id\n", "err 2 usage"),
            ("set f-slot1 lan-test\nset f-slot2 lan-test\n", "err 2 usage"),
            ("set f-slot1 lan-test", "err 2 usage"),
        ]:
            before = table()
            out = guest.succeed(f"printf %s {shlex.quote(line)} | socat -t 5 - UNIX-CONNECT:/run/permafrost-netctl.sock")
            assert out.strip() == reply, (line, out)
            assert table() == before

    with subtest("netctl is one command, with no shell and no forward"):
        passwd = guest.succeed("getent passwd netctl").strip()
        assert passwd.endswith("permafrost-netctl-ssh"), passwd
        assert "bash" not in passwd, passwd
        # A tty, a subsystem or a command all give the one command.
        for opts, cmd in [("-t", "id"), ("-s", "sftp"), ("-tt", "list")]:
            status, out = site.execute(ssh("netctl", "netctl", cmd, opts=opts))
            assert "uid=" not in out and "root" not in out, (opts, out)
        # A remote forward is refused, and ssh exits when it is told to.
        status, out = site.execute(
            ssh("netctl", "netctl", "list", opts="-o ExitOnForwardFailure=yes -R 7777:127.0.0.1:22")
        )
        assert status != 0, out
        # A local forward opens on the client and is refused when it is used.
        site.succeed(f"{SSH} -i /root/id-netctl -f -N -L 7778:127.0.0.1:22 netctl@{GUEST} < /dev/null")
        out = site.succeed(
            "python3 -c \"import socket; s=socket.create_connection(('127.0.0.1',7778)); "
            "s.settimeout(3); print(repr(s.recv(32)))\" || true"
        )
        assert "SSH-" not in out, out
        site.succeed("pkill -f '[s]sh .* -L 7778' || true")

    with subtest("concurrent changes leave each slot in exactly one profile"):
        lines = [
            ssh("netctl", "netctl", f"set {slot} {profile}", timeout=60)
            for _ in range(20)
            for slot in ["f-slot1", "f-slot2"]
            for profile in ["lan-test", "internet-only"]
        ]
        site.succeed("cat > /tmp/cmds <<'EOF'\n" + "\n".join(lines) + "\nEOF")
        # Ten logins at a time, each of which starts a user manager for netctl.
        status, _ = site.execute("rm -f /tmp/conc.out; xargs -d '\\n' -P 10 -I{} sh -c {} < /tmp/cmds >> /tmp/conc.out 2>&1")
        out = site.succeed("cat /tmp/conc.out").splitlines()
        assert status == 0 and len(out) == 80 and all(x.startswith("ok set ") for x in out), (status, out)
        for uid in [2001, 2002]:
            holders = [s for s in ["uids_internet_only", "uids_lan_test"] if uid in members(s)]
            assert len(holders) == 1, (uid, holders)
        assert 2003 in members("uids_internet_only")

    with subtest("a slot cannot run the helper or widen its own profile"):
        slot = "f-slot1"
        site.fail(ssh(slot, slot, "socat - UNIX-CONNECT:/run/permafrost-netctl.sock"))
        status, out = site.execute(
            ssh(slot, slot, "SSH_ORIGINAL_COMMAND='set f-slot1 lan-test' permafrost-netctl-ssh")
        )
        assert status == 6 and out.strip() == "err 6 internal", (status, out)
        before = table()
        site.fail(ssh(slot, slot, "type sudo"))
        site.fail(ssh(slot, slot, "systemctl start permafrost-netctl@x.service"))
        site.fail(ssh(slot, slot, "su - f-slot2 -c id"))
        site.succeed(ssh(slot, slot, "grep -q '^CapEff:.0000000000000000$' /proc/self/status"))
        site.fail(ssh(slot, slot, "nft add element inet permafrost uids_lan_test { 2001 }"))
        # `ss -K` of a slot closes no connection of another account.
        site.execute("rm -f /tmp/adhold.out; (" + ssh("adurable", "adurable", f"hold {lanIp} 80") + " > /tmp/adhold.out 2>&1 &)")
        site.wait_until_succeeds("grep -q '^up' /tmp/adhold.out", timeout=60)
        site.execute(ssh(slot, slot, f"ss -K -tn dst {lanIp}:80"))
        guest.succeed(f"ss -tn state established dst {lanIp}:80 | grep -q {lanIp}")
        assert "closed" not in site.succeed("cat /tmp/adhold.out")
        assert table() == before
        # The netctl login itself cannot write the sets either.
        guest.fail("su -s ${pkgs.runtimeShell} netctl -c 'nft list ruleset'")

    # --- Workspaces on the host ---------------------------------------------

    # The identity of a service that reads the workspaces, as the unit of the
    # reader has it: a dynamic user, the group of the reader, and nothing of the
    # real directory. No BindReadOnlyPaths here, on purpose: systemd would make
    # the path read-only inside the unit, and every write below would fail for
    # that reason and not for the mount of the module, which is the thing that
    # is under test. DynamicUser implies ProtectSystem=strict, which has the
    # same effect (and cannot be switched off), so the unit names the view in
    # ReadWritePaths and the mount is the only barrier left. The subtest that
    # makes the mount writable shows that a write then goes through.
    READER = (
        "systemd-run --quiet --wait --pipe --collect -p DynamicUser=yes "
        "-p SupplementaryGroups=permafrost-ws -p Environment=PATH=/run/current-system/sw/bin "
        "-p ReadWritePaths=/srv/permafrost-workspaces "
        "-p InaccessiblePaths=/var/lib/permafrost-workspaces "
    )
    TREE = "/var/lib/permafrost-workspaces"
    VIEW = "/srv/permafrost-workspaces"


    def reader(cmd):
        return READER + "sh -c " + shlex.quote(cmd)


    with subtest("the host tree has the owners and modes of the module"):
        lan.succeed("systemctl start permafrost-workspaces-ro-check.service")
        assert lan.succeed(f"stat -c '%a %u %g' {TREE}").strip() == "750 0 ${toString hostIdBase}"
        for n in [1, 2, 3]:
            assert lan.succeed(f"stat -c '%a %u %g' {TREE}/f-slot{n}").strip() == f"2750 {${toString hostIdBase} + n} ${toString hostIdBase}"
        assert lan.succeed("getent group permafrost-ws").startswith("permafrost-ws:x:${toString hostIdBase}:")
        # The numbers belong to no account.
        lan.fail("getent passwd ${toString (hostIdBase + 1)}")

    with subtest("the reader reads what a slot wrote and cannot write it"):
        # What a slot makes through the id map: an owner without a passwd
        # entry, the group of the reader, mode 0640 and 2750.
        lan.succeed(
            f"install -d -m 2750 -o {${toString hostIdBase} + 1} -g ${toString hostIdBase} {TREE}/f-slot1/repo",
            f"install -m 0640 -o {${toString hostIdBase} + 1} -g ${toString hostIdBase} /dev/null {TREE}/f-slot1/repo/file",
            f"echo hello > {TREE}/f-slot1/repo/file",
        )
        opts = lan.succeed(f"findmnt -n -o OPTIONS --mountpoint {VIEW}").strip().splitlines()[-1].split(",")
        for need in ["ro", "nosymfollow", "nosuid", "nodev"]:
            assert need in opts, (need, opts)
        assert lan.succeed(reader(f"cat {VIEW}/f-slot1/repo/file")).strip() == "hello"
        assert lan.succeed(reader(f"ls {VIEW}/f-slot1/repo")).strip() == "file"
        # The real directory is not there for the reader at all. The same unit
        # reads the view in the line above, so the refusal is of the path.
        status, out = lan.execute(reader(f"ls {TREE}") + " 2>&1")
        assert status != 0 and TREE in out, (status, out)
        # The kernel checks the mount before the mode for a create, a delete
        # and a chmod, so these name the mount. An open for writing of a file
        # that is 0640 for the group fails on the mode first, so that one only
        # has to fail here; the subtest below gives it write bits and asks again.
        status, out = lan.execute(reader(f"echo x >> {VIEW}/f-slot1/repo/file") + " 2>&1")
        assert status != 0, out
        for cmd in [
            f"touch {VIEW}/f-slot1/repo/new",
            f"rm -f {VIEW}/f-slot1/repo/file",
            f"chmod 777 {VIEW}/f-slot1/repo/file",
        ]:
            status, out = lan.execute(reader(cmd) + " 2>&1")
            assert status != 0 and "Read-only file system" in out, (cmd, status, out)
        assert lan.succeed(f"cat {TREE}/f-slot1/repo/file").strip() == "hello"
        # An account outside the group does not even list the tree. The reader
        # account, which is in the group, lists the same view.
        lan.succeed(f"runuser -u reader -- ls {VIEW}/f-slot1/repo")
        for path in [TREE, VIEW]:
            status, out = lan.execute(f"runuser -u outsider -- ls {path} 2>&1")
            assert status != 0 and "Permission denied" in out and path in out, (path, status, out)

    with subtest("the mount, and not the mode, is the barrier"):
        # A slot owns its tree and can give the group of the reader write bits.
        lan.succeed(f"chmod -R g+w {TREE}/f-slot1")
        # Through the real directory the group can now write. This is why the
        # reader must never see that path.
        lan.succeed(f"runuser -u reader -- touch {TREE}/f-slot1/repo/by-group")
        lan.succeed(f"rm {TREE}/f-slot1/repo/by-group")
        for cmd in [
            f"echo x >> {VIEW}/f-slot1/repo/file",
            f"touch {VIEW}/f-slot1/repo/new",
            f"rm -f {VIEW}/f-slot1/repo/file",
            f"mkdir {VIEW}/f-slot1/repo/dir",
            f"chmod 777 {VIEW}/f-slot1/repo/file",
        ]:
            status, out = lan.execute(reader(cmd) + " 2>&1")
            assert status != 0 and "Read-only file system" in out, (cmd, out)
        assert lan.succeed(f"cat {TREE}/f-slot1/repo/file").strip() == "hello"
        # Take the barrier away and the same write works, so the refusals above
        # are the mount's and nothing else's.
        lan.succeed("systemctl start reader-stub.service")
        lan.succeed("systemctl stop reader-stub.service")
        lan.succeed(f"mount -o remount,bind,rw {VIEW}")
        lan.succeed(reader(f"touch {VIEW}/f-slot1/repo/new-rw && rm {VIEW}/f-slot1/repo/new-rw"))
        # The check fails on a writable mount, and so does the start of a unit
        # that requires it (the reader of stage 6), every time and not once.
        status, out = lan.execute("systemctl start permafrost-workspaces-ro-check.service 2>&1")
        assert status != 0, out
        assert "lacks ro" in lan.succeed("journalctl -u permafrost-workspaces-ro-check.service --no-pager -o cat")
        status, out = lan.execute("systemctl start reader-stub.service 2>&1")
        assert status != 0 and "dependency" in out.lower(), (status, out)
        assert lan.execute("systemctl is-active reader-stub.service")[0] != 0
        # Put the mount right again: the reader starts, and the write fails.
        lan.succeed(f"umount {VIEW} && mount {VIEW}")
        lan.succeed("systemctl start reader-stub.service")
        lan.succeed("systemctl stop reader-stub.service")
        status, out = lan.execute(reader(f"touch {VIEW}/f-slot1/repo/new") + " 2>&1")
        assert status != 0 and "Read-only file system" in out, out

    with subtest("the reader does not follow a link that a slot made"):
        # Made as a slot would make it, so it has the owner of a slot.
        lan.succeed(f"ln -s /etc/passwd {TREE}/f-slot1/repo/link")
        lan.succeed(f"chown -h {${toString hostIdBase} + 1}:${toString hostIdBase} {TREE}/f-slot1/repo/link")
        lan.succeed(f"cat {TREE}/f-slot1/repo/link")
        status, out = lan.execute(reader(f"cat {VIEW}/f-slot1/repo/link") + " 2>&1")
        assert status != 0 and "Too many levels of symbolic links" in out, (status, out)
        assert lan.succeed(reader(f"readlink {VIEW}/f-slot1/repo/link")).strip() == "/etc/passwd"

    def last_found():
        out = lan.succeed("journalctl -t permafrost-ws-audit --no-pager -o cat")
        return [x for x in out.splitlines() if x.startswith("found ")][-1]


    with subtest("the audit finds a file that no slot owns"):
        lan.succeed("systemctl start permafrost-workspaces-audit.service")
        journal = lan.succeed("journalctl -t permafrost-ws-audit --no-pager")
        assert "owner outside the slot ids" not in journal, journal
        assert last_found() == "found 0", journal
        # Each bound of the audit has a file of its own, and the line names the
        # owner it found: a real account of the host below the range (the uid
        # and the gid of the account), a uid above the last slot, a gid above
        # it, and a gid below the reader group. Then a file name that tries to
        # start a line of its own in the journal; that file belongs to root, so
        # it is a finding too. The count is that of the last run.
        base = ${toString hostIdBase}
        lan.succeed(
            f"chown 2001:2001 {TREE}/f-slot1/repo/file",
            f"install -m 0640 -o {base + 4} -g {base} /dev/null {TREE}/f-slot1/repo/uid-above",
            f"install -m 0640 -o {base + 1} -g {base + 4} /dev/null {TREE}/f-slot1/repo/gid-above",
            f"install -m 0640 -o {base + 1} -g 2001 /dev/null {TREE}/f-slot1/repo/gid-below",
            f"touch \"{TREE}/f-slot1/repo/a\nFORGED-LINE\"",
        )
        lan.succeed("systemctl start permafrost-workspaces-audit.service")
        journal = lan.succeed("journalctl -t permafrost-ws-audit --no-pager")
        for owner, name in [
            ("2001:2001", "file"),
            (f"{base + 4}:{base}", "uid-above"),
            (f"{base + 1}:{base + 4}", "gid-above"),
            (f"{base + 1}:2001", "gid-below"),
            (f"0:{base}", "a?FORGED-LINE"),
        ]:
            assert f"owner outside the slot ids: {owner} {TREE}/f-slot1/repo/{name}" in journal, (name, journal)
        assert "FORGED-LINE" not in journal.replace("a?FORGED-LINE", ""), journal
        assert last_found() == "found 5", journal
        # What is inside the ids is not a finding: the files of slot 1 and 3.
        lan.succeed(f"chown {base + 1}:{base} {TREE}/f-slot1/repo/file")
        lan.succeed(f"find {TREE}/f-slot1/repo -name 'a*' -delete")
        lan.succeed(f"find {TREE}/f-slot1/repo \\( -name 'uid-*' -o -name 'gid-*' \\) -delete")
        lan.succeed("systemctl start permafrost-workspaces-audit.service")
        assert last_found() == "found 0"

    with subtest("the guard of the runner refuses a symlink and leaves what it points at"):
        lan.succeed(
            "mkdir /root/sentinel",
            "install -m 0600 -o 1234 -g 1234 /dev/null /root/sentinel/file",
            f"rm -r {TREE}/f-slot2 && ln -s /root/sentinel {TREE}/f-slot2",
        )
        before = lan.succeed("stat -c '%a %u %g' /root/sentinel /root/sentinel/file")
        # The first is what the runner does for a good directory, the second
        # for the link.
        lan.succeed(f"bash -c '. ${safeDir}; safe_dir {TREE}/f-slot1'")
        lan.succeed(f"bash -c '. ${safeDir}; safe_dir {TREE}/f-nothing'")
        # A link higher up is the business of the host: the guard looks at the
        # directory itself, and the realpath of a directory that is not a link
        # is its parent's realpath and its name.
        lan.succeed(f"ln -s {TREE} /root/treelink")
        lan.succeed("bash -c 'set -e; . ${safeDir}; safe_dir /root/treelink/f-slot1'")
        lan.succeed(f"ln -s {TREE}/f-slot1 /root/slotlink")
        status, out = lan.execute("bash -c 'set -e; . ${safeDir}; safe_dir /root/slotlink' 2>&1")
        assert status == 1 and "is a symlink" in out, (status, out)
        status, out = lan.execute(f"bash -c 'set -e; . ${safeDir}; safe_dir {TREE}/f-slot2; echo not-reached' 2>&1")
        assert status == 1 and "is a symlink" in out and "not-reached" not in out, (status, out)
        assert lan.succeed("stat -c '%a %u %g' /root/sentinel /root/sentinel/file") == before
        # A file where a directory belongs is refused too.
        lan.succeed(f"touch {TREE}/afile")
        status, out = lan.execute(f"bash -c 'set -e; . ${safeDir}; safe_dir {TREE}/afile' 2>&1")
        assert status == 1 and "is not a directory" in out, (status, out)

    def sshd_refused_while(guard):
        # The guard is failed: sshd went down with it, and a start is refused.
        # Both halves of the wiring are read from systemd as well.
        assert guest.execute("systemctl is-active sshd.service")[0] != 0
        status, out = guest.execute("systemctl start sshd.service 2>&1")
        assert status != 0 and "dependency" in out.lower(), (status, out)
        assert guest.execute("systemctl is-active sshd.service")[0] != 0
        assert f"{guard}.service" in guest.succeed("systemctl show sshd.service -p Requires -p After")


    with subtest("sshd waits for the guard, and the guard fails while the share root is open"):
        guest.succeed("chmod 755 ${slotLib.shareRoot}")
        guest.fail("systemctl restart permafrost-factory-guard.service")
        sshd_refused_while("permafrost-factory-guard")
        guest.succeed("chmod 700 ${slotLib.shareRoot}")
        guest.succeed("systemctl restart permafrost-factory-guard.service")
        guest.succeed("systemctl start sshd.service")
        guest.wait_for_unit("sshd.service")
        assert site.succeed(ssh("f-slot1", "f-slot1", "id -un")).strip() == "f-slot1"

    with subtest("sshd waits for the egress table, and the guard fails without it"):
        # The table that did not load at boot: every slot would reach the LAN.
        guest.succeed("systemctl is-active permafrost-egress-guard.service")
        guest.succeed("nft delete table inet permafrost")
        guest.fail("systemctl restart permafrost-egress-guard.service")
        sshd_refused_while("permafrost-egress-guard")
        assert "not loaded" in guest.succeed("journalctl -u permafrost-egress-guard.service --no-pager -o cat")
        guest.succeed("systemctl restart nftables.service")
        guest.succeed("systemctl restart permafrost-egress-guard.service")
        guest.succeed("systemctl start sshd.service")
        guest.wait_for_unit("sshd.service")
        assert site.succeed(ssh("f-slot1", "f-slot1", "id -un")).strip() == "f-slot1"
        rejected("f-slot1", lanIp, 80)
  '';
}
