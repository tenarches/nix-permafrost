{ lib, ... }:

let
  slots = import ../_lib/slots.nix;
  socketPath = "/run/permafrost-netctl.sock";
  wrapperName = "permafrost-netctl-ssh";
in
{
  # The one way to change the network profile of a slot while the guest runs.
  #
  # The harness logs in over ssh as `netctl` with a CA certificate, says which
  # slot gets which profile, and a small helper moves the uid of that slot
  # between the sets of the egress table (network-egress.nix). A slot cannot do
  # it: no slot can obtain a certificate for `netctl` (the Vault role that signs
  # it belongs to the harness, which is outside this repository), and the
  # helper socket is closed to every other account.
  #
  # The chain:
  #
  # - `netctl` has the wrapper as its login shell and as the ForceCommand. It
  #   reads `$SSH_ORIGINAL_COMMAND`, checks it against the grammar below, and
  #   sends one line to the helper socket. There is no shell to escape into,
  #   no tty, no forwarding of any kind, and no home.
  # - The socket is `root:netctl 0660`, so only that account (and root) can
  #   connect. No sudo and no polkit: base.nix removed the one, and the other
  #   would add a daemon and a D-Bus surface for what a file mode does.
  # - One helper process owns the socket and serves one connection after the
  #   other, so two changes for one slot cannot both read the old profile. It
  #   runs as a dynamic user with CAP_NET_ADMIN and no inet socket: nft and
  #   `ss -K` use netlink only, so a hijacked helper cannot call out. It exits
  #   after ten idle seconds, and the socket starts it again.
  #
  # The grammar (the wrapper checks it, and the helper checks it again):
  #
  #   list
  #   get <slot>
  #   set <slot> <profile>
  #
  # One line of at most 64 characters from `a-z 0-9 -` and single spaces. No
  # verb takes a host, a port, an address or a uid. The slot and the profile
  # are looked up in a table that is written at build time, and the nft text is
  # a fixed template with one number in it. Answers are one line, `ok ...` or
  # `err <code> <word>`. The exit status is the code: 0 ok, 2 grammar, 3 slot
  # not declared, 4 profile not declared, 5 nft refused, 6 internal.
  #
  # After a change the helper closes the established TCP connections of that
  # slot, because a connection that the new profile does not allow would
  # otherwise wait for its next packet to die. Whether it was a widening or a
  # narrowing is for the harness to decide. UDP and raw sockets are not closed;
  # the rules reject their next packet.
  #
  # Not closed: CAP_NET_ADMIN lets a hijacked helper rewrite the whole ruleset,
  # not only the uid sets. The limit is the size of the helper (one short
  # Python file, no input beyond the grammar, no network) and the socket mode.
  # The change is not stored. A reboot or `systemctl reload nftables` puts
  # every slot back in the default profile.
  flake.modules.nixos.guest-netctl =
    { config, pkgs, ... }:

    let
      cfg = config.permafrost.netctl;
      slotCfg = config.permafrost.slots;
      netCfg = config.permafrost.network;

      # The tables the helper may use, fixed at build time.
      table = pkgs.writeText "permafrost-netctl.json" (
        builtins.toJSON {
          nft = "${pkgs.nftables}/bin/nft";
          ss = "${pkgs.iproute2}/bin/ss";
          slots = lib.listToAttrs (
            map (n: lib.nameValuePair (slots.name slotCfg n) (slots.uid slotCfg n)) (lib.range 1 slotCfg.count)
          );
          profiles = lib.genAttrs (lib.attrNames netCfg.profiles) slots.uidSet;
          default = netCfg.defaultProfile;
        }
      );

      helper = pkgs.writers.writePython3Bin "permafrost-netctl-helper" { flakeIgnore = [ "E501" ]; } ''
        import ipaddress
        import json
        import os
        import re
        import socket
        import subprocess
        import sys

        with open("${table}") as f:
            CFG = json.load(f)
        NFT = CFG["nft"]
        SS = CFG["ss"]

        LINE = re.compile(r"[a-z0-9 -]{1,64}")
        TOKEN = re.compile(r"[a-z][a-z0-9-]{0,30}")
        # The only two lines that nft is ever given.
        NFT_LINE = re.compile(r"(delete|add) element inet permafrost uids_[a-z0-9_]+ \{ [0-9]+ \}")
        CODES = {"usage": 2, "slot": 3, "profile": 4, "apply": 5, "internal": 6}


        class Refused(Exception):
            def __init__(self, word):
                super().__init__(word)
                self.word = word


        def log(msg):
            print(msg, flush=True)


        def run(argv, stdin=None):
            return subprocess.run(
                argv, input=stdin, capture_output=True, text=True,
                shell=False, timeout=5, check=False,
            )


        def members():
            """Profile name -> the uids in its set, read from the kernel."""
            found = {}
            for profile, setname in CFG["profiles"].items():
                # -nnn: uids as numbers, not as the names nft would look up.
                r = run([NFT, "-nnn", "-j", "list", "set", "inet", "permafrost", setname])
                if r.returncode != 0:
                    raise Refused("internal")
                elems = []
                for item in json.loads(r.stdout)["nftables"]:
                    if "set" in item:
                        elems = item["set"].get("elem", [])
                found[profile] = {int(e) for e in elems if isinstance(e, int) or str(e).isdigit()}
            return found


        def endpoint(text):
            """An address and port as ss prints them, or None."""
            host, _, port = text.rpartition(":")
            host = host.strip("[]")
            try:
                ipaddress.ip_address(host)
            except ValueError:
                return None
            if not port.isdigit() or int(port) > 65535:
                return None
            return text


        def kill(uid):
            """Close the established TCP connections of one uid. Returns (n, supported)."""
            r = run([SS, "-tanHe", "state", "established"])
            killed = 0
            supported = True
            for line in r.stdout.splitlines():
                m = re.search(r"(?:^| )uid:([0-9]+)(?: |$)", line)
                if not m or int(m.group(1)) != uid:
                    continue
                t = line.split()
                if t[0].isalpha():
                    t = t[1:]
                local, peer = endpoint(t[2]), endpoint(t[3])
                if local is None or peer is None:
                    continue
                k = run([SS, "-K", "-tn", "src", local, "dst", peer])
                if k.returncode == 0:
                    killed += 1 if "ESTAB" in k.stdout else 0
                else:
                    supported = False
            return killed, supported


        def change(slot, new):
            uid = CFG["slots"][slot]
            current = [p for p, u in members().items() if uid in u]
            if current == [new]:
                return f"ok set slot={slot} uid={uid} profile={new} unchanged"
            lines = [f"delete element inet permafrost {CFG['profiles'][p]} {{ {uid} }}" for p in current]
            lines.append(f"add element inet permafrost {CFG['profiles'][new]} {{ {uid} }}")
            if not all(NFT_LINE.fullmatch(x) for x in lines):
                raise Refused("internal")
            # One transaction: both lines or none.
            if run([NFT, "-f", "-"], "\n".join(lines) + "\n").returncode != 0:
                raise Refused("apply")
            killed, supported = kill(uid)
            old = ",".join(current) or "none"
            log(f"netctl set slot={slot} uid={uid} from={old} to={new} killed={killed}")
            if not supported:
                log("netctl kill=unsupported")
                return f"ok set slot={slot} uid={uid} from={old} to={new} killed={killed} kill=unsupported"
            return f"ok set slot={slot} uid={uid} from={old} to={new} killed={killed}"


        def answer(line):
            if not LINE.fullmatch(line):
                raise Refused("usage")
            parts = line.split(" ")
            if parts == ["list"]:
                return "ok list default={} profiles={}".format(CFG["default"], ",".join(sorted(CFG["profiles"])))
            if parts[0] == "get" and len(parts) == 2 and TOKEN.fullmatch(parts[1]):
                slot = parts[1]
                if slot not in CFG["slots"]:
                    raise Refused("slot")
                uid = CFG["slots"][slot]
                now = [p for p, u in members().items() if uid in u]
                log(f"netctl get slot={slot}")
                return f"ok get slot={slot} uid={uid} profile={','.join(now) or 'none'}"
            if parts[0] == "set" and len(parts) == 3 and all(TOKEN.fullmatch(p) for p in parts[1:]):
                slot, profile = parts[1:]
                if slot not in CFG["slots"]:
                    raise Refused("slot")
                if profile not in CFG["profiles"]:
                    raise Refused("profile")
                return change(slot, profile)
            raise Refused("usage")


        def handle(conn):
            conn.settimeout(5)
            buf = b""
            while b"\n" not in buf and len(buf) < 256:
                chunk = conn.recv(256)
                if not chunk:
                    break
                buf += chunk
            line = buf.decode("ascii", "replace")
            try:
                if not line.endswith("\n") or line.count("\n") != 1:
                    raise Refused("usage")
                reply = answer(line[:-1])
            except Refused as e:
                reply = f"err {CODES[e.word]} {e.word}"
                log(f"netctl reject code={CODES[e.word]} reason={e.word} input={ascii(line[:64])}")
            except Exception as e:
                reply = "err 6 internal"
                log(f"netctl internal error {type(e).__name__} input={ascii(line[:64])}")
            conn.sendall((reply + "\n").encode("ascii"))


        def main():
            if os.environ.get("LISTEN_PID") != str(os.getpid()) or os.environ.get("LISTEN_FDS") != "1":
                sys.exit("netctl: start through the socket unit")
            srv = socket.socket(fileno=3)
            srv.settimeout(10)
            while True:
                try:
                    conn, _ = srv.accept()
                except socket.timeout:
                    return
                with conn:
                    try:
                        handle(conn)
                    except OSError as e:
                        log(f"netctl connection error {type(e).__name__}")


        main()
      '';

      # The login shell of `netctl` and its ForceCommand.
      wrapperBase = pkgs.writeShellApplication {
        name = wrapperName;
        runtimeInputs = [
          pkgs.socat
          pkgs.util-linux
        ];
        text = ''
          # The ranges below are by byte, not by the collation of a locale.
          export LC_ALL=C

          cmd=''${SSH_ORIGINAL_COMMAND-}
          peer=''${SSH_CONNECTION%% *}

          # The same grammar as the helper's, checked before anything is sent.
          re='^[a-z0-9 -]{1,64}$'
          if [[ $cmd == *$'\n'* || ! $cmd =~ $re ]]; then
            logger -t permafrost-netctl "netctl-ssh peer=$peer rejected"
            echo "err 2 usage"
            exit 2
          fi
          logger -t permafrost-netctl "netctl-ssh peer=$peer accepted"

          # The helper serves one connection after the other, so a caller may wait
          # for those in front of it. socat waits this long for the answer.
          reply=$(printf '%s\n' "$cmd" | socat -t 30 - UNIX-CONNECT:${socketPath} 2>/dev/null) || reply=""
          reply=''${reply%%$'\n'*}

          ok='^ok [ -~]{0,200}$'
          err='^err ([2-6]) [a-z]+$'
          if [[ $reply =~ $ok ]]; then
            echo "$reply"
          elif [[ $reply =~ $err ]]; then
            echo "$reply"
            exit "''${BASH_REMATCH[1]}"
          else
            echo "err 6 internal"
            exit 6
          fi
        '';
      };
      # users.users.<name>.shell wants the path of the program inside the package.
      wrapper = wrapperBase // {
        shellPath = "/bin/${wrapperName}";
      };
    in
    {
      options.permafrost.netctl.enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          The `netctl` login and the helper that moves a slot between the
          network profiles. It needs the egress table of
          `guest-network-egress`, which sits in the guest next to this module.
        '';
      };

      config = lib.mkIf cfg.enable {
        users = {
          groups.netctl.gid = slots.netctl.uid;

          users.${slots.netctl.name} = {
            isNormalUser = true;
            uid = slots.netctl.uid;
            group = "netctl";
            home = "/var/empty";
            createHome = false;
            shell = wrapper;
            hashedPassword = "!";
            extraGroups = [ ];
          };
        };

        environment.systemPackages = [ wrapper ];

        # Login is by CA certificate only (the principal is `netctl`), and the
        # wrapper is the one command. Both PermitOpen and PermitListen are none
        # a second time on top of AllowTcpForwarding, so no sshd feature that
        # skips one of the lines opens a forward. mkAfter, as in slots.nix.
        services.openssh.extraConfig = lib.mkAfter ''
          Match User ${slots.netctl.name}
            AuthorizedKeysFile none
            ForceCommand /run/current-system/sw/bin/${wrapperName}
            PermitOpen none
            PermitListen none
            PermitTTY no
            AllowAgentForwarding no
            AllowTcpForwarding no
            AllowStreamLocalForwarding no
            X11Forwarding no
            PermitTunnel no
            PermitUserRC no
        '';

        systemd.sockets.permafrost-netctl = {
          wantedBy = [ "sockets.target" ];
          listenStreams = [ socketPath ];
          socketConfig = {
            SocketUser = "root";
            SocketGroup = "netctl";
            SocketMode = "0660";
            Accept = false;
          };
        };

        systemd.services.permafrost-netctl = {
          description = "Network profile helper for the factory slots";
          serviceConfig = {
            ExecStart = "${helper}/bin/permafrost-netctl-helper";
            SyslogIdentifier = "permafrost-netctl";
            DynamicUser = true;
            # nft sets and `ss -K` need this, and nothing else.
            AmbientCapabilities = [ "CAP_NET_ADMIN" ];
            CapabilityBoundingSet = [ "CAP_NET_ADMIN" ];
            NoNewPrivileges = true;
            ProtectSystem = "strict";
            ProtectHome = true;
            PrivateTmp = true;
            PrivateDevices = true;
            # Netlink for nft and ss, the unix socket for the client. No inet
            # socket: a hijacked helper cannot reach the network.
            RestrictAddressFamilies = [
              "AF_UNIX"
              "AF_NETLINK"
            ];
            SystemCallFilter = [ "@system-service" ];
            MemoryDenyWriteExecute = true;
            LockPersonality = true;
          };
        };
      };
    };
}
