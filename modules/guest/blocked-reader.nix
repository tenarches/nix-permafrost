{ lib, ... }:

let
  slots = import ../_lib/slots.nix;
in
{
  # The log reader behind the `blocked` verb of the `netctl` login (netctl.nix
  # has the wrapper and the grammar).
  #
  # `blocked <slot> <since>` answers with the addresses and ports that the slot
  # tried to reach and the egress table refused (network-egress.nix puts a log
  # line before each reject rule). The harness asks after a tool call failed with
  # a network error, with the time that the call started, so that an old line is
  # never taken for a later failure. The answer is information for a person who
  # decides about a wider profile. It never changes a rule, and it is not a
  # complete list: the log rule is rate limited, and the kernel log can lose a
  # line under load.
  #
  # The answer is `ok blocked slot=f-slot3 n=<k> <address>:<port>,...`: at most
  # ten different destinations, the most recent first, from the log lines at or
  # after `since` (epoch seconds) that carry the uid of the slot. An IPv6 address
  # is in brackets. `n` is the number of destinations in the list, and `n=0` has
  # no list.
  #
  # Its own unit and socket, apart from the net helper, because the net helper
  # has CAP_NET_ADMIN and no way to read a log, and the reader has a log and no
  # capability: a dynamic user in the group `systemd-journal`, no inet socket, a
  # read-only system. It runs a fixed `journalctl` and reads its output; nothing
  # the caller sends reaches the command line except a number that it has
  # checked.
  flake.modules.nixos.guest-blocked-reader =
    {
      config,
      pkgs,
      ...
    }:

    let
      cfg = config.permafrost.blockedReader;
      slotCfg = config.permafrost.slots;

      table = pkgs.writeText "permafrost-blocked.json" (
        builtins.toJSON {
          journalctl = "${config.systemd.package}/bin/journalctl";
          prefix = slots.logPrefix;
          slots = lib.listToAttrs (
            map (n: lib.nameValuePair (slots.name slotCfg n) (slots.uid slotCfg n)) (lib.range 1 slotCfg.count)
          );
        }
      );

      helper = pkgs.writers.writePython3Bin "permafrost-blocked-helper" { flakeIgnore = [ "E501" ]; } ''
        import ipaddress
        import json
        import os
        import re
        import socket
        import subprocess
        import sys

        with open("${table}") as f:
            CFG = json.load(f)

        LINE = re.compile(r"[a-z0-9 -]{1,64}")
        TOKEN = re.compile(r"[a-z][a-z0-9-]{0,30}")
        SINCE = re.compile(r"[0-9]{1,11}")
        CODES = {"usage": 2, "slot": 3, "internal": 6}
        MAX = 10


        class Refused(Exception):
            def __init__(self, word):
                super().__init__(word)
                self.word = word


        def log(msg):
            print(msg, flush=True)


        def field(line, key):
            m = re.search(r"(?:^| )" + key + r"=([0-9A-Fa-f:.]+)(?: |$)", line)
            return m.group(1) if m else None


        def blocked(slot, since):
            uid = str(CFG["slots"][slot])
            r = subprocess.run(
                [CFG["journalctl"], "-k", "--no-pager", "-q", "-r", "-o", "cat", "--since", f"@{since}"],
                capture_output=True, text=True, shell=False, timeout=10, check=False,
            )
            if r.returncode != 0:
                raise Refused("internal")
            seen = []
            for line in r.stdout.splitlines():
                if not line.startswith(CFG["prefix"]):
                    continue
                if field(line, "UID") != uid:
                    continue
                dst, port = field(line, "DST"), field(line, "DPT")
                if dst is None or port is None:
                    continue
                # The kernel prints an IPv6 address in full (fd00:0099:...), so it is
                # put in the usual short form, and a line that is no address is dropped.
                try:
                    addr = ipaddress.ip_address(dst)
                except ValueError:
                    continue
                where = f"[{addr}]:{port}" if addr.version == 6 else f"{addr}:{port}"
                if where not in seen:
                    seen.append(where)
                if len(seen) == MAX:
                    break
            log(f"blocked slot={slot} since={since} n={len(seen)}")
            head = f"ok blocked slot={slot} n={len(seen)}"
            return head + (" " + ",".join(seen) if seen else "")


        def answer(line):
            if not LINE.fullmatch(line):
                raise Refused("usage")
            parts = line.split(" ")
            if len(parts) != 3 or parts[0] != "blocked" or not TOKEN.fullmatch(parts[1]) or not SINCE.fullmatch(parts[2]):
                raise Refused("usage")
            if parts[1] not in CFG["slots"]:
                raise Refused("slot")
            return blocked(parts[1], int(parts[2]))


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
                log(f"blocked reject code={CODES[e.word]} reason={e.word} input={ascii(line[:64])}")
            except Exception as e:
                reply = "err 6 internal"
                log(f"blocked internal error {type(e).__name__} input={ascii(line[:64])}")
            conn.sendall((reply + "\n").encode("ascii"))


        def main():
            if os.environ.get("LISTEN_PID") != str(os.getpid()) or os.environ.get("LISTEN_FDS") != "1":
                sys.exit("blocked: start through the socket unit")
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
                        log(f"blocked connection error {type(e).__name__}")


        main()
      '';
    in
    {
      options.permafrost.blockedReader.enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          The reader of the kernel log behind the `blocked` verb of the
          `netctl` login. It needs `guest-netctl` (the login) and
          `guest-network-egress` (the log lines).
        '';
      };

      config = lib.mkIf cfg.enable {
        systemd = {
          sockets.permafrost-blocked = {
            wantedBy = [ "sockets.target" ];
            listenStreams = [ slots.sockets.blocked ];
            socketConfig = {
              SocketUser = "root";
              SocketGroup = "netctl";
              SocketMode = "0660";
              Accept = false;
            };
          };

          services.permafrost-blocked = {
            description = "Read the refused connections of a factory slot from the kernel log";
            serviceConfig = {
              ExecStart = "${helper}/bin/permafrost-blocked-helper";
              SyslogIdentifier = "permafrost-blocked";
              DynamicUser = true;
              SupplementaryGroups = [ "systemd-journal" ];
              CapabilityBoundingSet = [ "" ];
              NoNewPrivileges = true;
              ProtectSystem = "strict";
              ProtectHome = true;
              PrivateTmp = true;
              PrivateDevices = true;
              # The socket arrives as a file descriptor, and the journal is read
              # from files: no inet socket, no netlink.
              RestrictAddressFamilies = [ "AF_UNIX" ];
              LockPersonality = true;
            };
          };
        };
      };
    };
}
