# VM check of the factory slot accounts (guest/slots.nix) next to adurable, of
# the egress table (guest/network-egress.nix) and of netctl (guest/netctl.nix).
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
      { lib, ... }:
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

        permafrost = {
          slots.count = 3;
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
      { lib, ... }:
      {
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

    with subtest("a reload of the table puts every slot back on the default profile"):
        assert netctl("set f-slot2 lan-test")[0] == 0
        assert members("uids_lan_test") == [2002]
        guest.succeed("systemctl reload nftables")
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
  '';
}
