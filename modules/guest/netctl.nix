{ lib, ... }:

let
  slots = import ../_lib/slots.nix;
  socketPath = slots.sockets.netctl;
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
  #   describe
  #   get <slot>
  #   set <slot> <profile> [<digest>]
  #   restore
  #   wipe <slot>          (slotctl.nix)
  #   stopjobs <slot>      (slotctl.nix)
  #   blocked <slot> <since>   (blocked-reader.nix)
  #
  # One line of at most 64 characters from `a-z 0-9 -` and single spaces. No
  # verb takes a host, a port, an address or a uid. The slot and the profile
  # are looked up in a table that is written at build time, and the nft text is
  # a fixed template with one number in it. Answers are one line, `ok ...` or
  # `err <code> <word>`. The exit status is the code: 0 ok, 2 grammar, 3 slot
  # not declared, 4 profile not declared, 5 nft refused, 6 internal, 7 busy,
  # 8 a wipe step failed, 9 the digest of `set` is not the build's.
  #
  # The wrapper sends `wipe` and `stopjobs` to the socket of the root helper in
  # slotctl.nix and `blocked` to the log reader in blocked-reader.nix. Those
  # are separate units, so a bug in either cannot touch nft: this helper keeps
  # CAP_NET_ADMIN and nothing else. `describe` says which verbs the guest
  # serves, so a harness can tell an old guest from a grammar bug.
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
  # The profile of each slot is kept in /run, so it lasts until the next boot and
  # no longer. A reload of nftables.service (a deploy that changes an unrelated
  # rule does that) deletes the table and loads it again, which would put every
  # slot back in the default profile and widen a slot that was narrowed. So
  # permafrost-netctl-restore runs after each reload or restart of
  # nftables.service and asks the helper for `restore`, which applies the
  # recorded profiles again and closes the TCP connections of the slots that it
  # narrows. Between the reload and the restore (a short time: the reload of the
  # restore unit is queued, not waited for) the slots have the default profile. `restore` changes nothing else, so it is safe to
  # call from the netctl login too. A reboot puts every slot back in the
  # default profile.
  flake.modules.nixos.guest-netctl =
    { config, pkgs, ... }:

    let
      cfg = config.permafrost.netctl;
      slotCfg = config.permafrost.slots;
      netCfg = config.permafrost.network;

      # The recorded profiles. The runtime directory of the helper outlives the
      # process (RuntimeDirectoryPreserve), and /run does not outlive a boot.
      statePath = "/run/permafrost-netctl/state.json";

      # What a console may show of a profile, and the digest that `set` can
      # carry. The digest is the first 16 hex digits of the sha256 of the
      # canonical JSON (builtins.toJSON sorts the keys) of the hosts, the ports
      # and the internet rule, so it changes when and only when what the profile
      # opens changes. A text change (title, description) does not change it.
      profileDigest =
        p:
        builtins.substring 0 16 (
          builtins.hashString "sha256" (
            builtins.toJSON {
              lan = map (e: { inherit (e) address ports; }) p.lan;
              internet = {
                inherit (p.internet) enable;
                tcpPorts = lib.optionals p.internet.enable p.internet.tcpPorts;
              };
            }
          )
        );

      # The verbs this guest serves. A unit that is not imported is not listed.
      has = name: lib.attrByPath [ "permafrost" name "enable" ] false config;
      verbs = [
        "list"
        "describe"
        "get"
        "set"
        "restore"
      ]
      ++ lib.optionals (has "slotctl") [
        "wipe"
        "stopjobs"
      ]
      ++ lib.optionals (has "blockedReader") [ "blocked" ];

      describe = {
        proto = 2;
        inherit verbs;
        default = netCfg.defaultProfile;
        profiles = map (name: {
          inherit name;
          inherit (netCfg.profiles.${name}) title description;
          lan = map (e: { inherit (e) address ports; }) netCfg.profiles.${name}.lan;
          internet = { inherit (netCfg.profiles.${name}.internet) enable tcpPorts; };
          digest = profileDigest netCfg.profiles.${name};
        }) (lib.attrNames netCfg.profiles);
      };

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
          digests = lib.mapAttrs (_: profileDigest) netCfg.profiles;
          inherit describe;
          state = statePath;
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
        DIGEST = re.compile(r"[0-9a-f]{16}")
        CODES = {"usage": 2, "slot": 3, "profile": 4, "apply": 5, "internal": 6, "changed": 9}


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


        def save():
            """Record the profile of every slot, as the kernel has it now."""
            now = members()
            state = {}
            for slot, uid in CFG["slots"].items():
                held = [p for p, u in now.items() if uid in u]
                if len(held) == 1:
                    state[slot] = held[0]
            tmp = CFG["state"] + ".new"
            with open(tmp, "w") as f:
                json.dump(state, f)
            os.replace(tmp, CFG["state"])


        def restore():
            try:
                with open(CFG["state"]) as f:
                    state = json.load(f)
            except FileNotFoundError:
                return "ok restore nothing"
            now = members()
            lines = []
            moved = []
            for slot, profile in sorted(state.items()):
                # A slot or a profile that a deploy took away is not restored.
                if slot not in CFG["slots"] or profile not in CFG["profiles"]:
                    continue
                uid = CFG["slots"][slot]
                current = [p for p, u in now.items() if uid in u]
                if current == [profile]:
                    continue
                lines += [f"delete element inet permafrost {CFG['profiles'][p]} {{ {uid} }}" for p in current]
                lines.append(f"add element inet permafrost {CFG['profiles'][profile]} {{ {uid} }}")
                moved.append((slot, uid, profile))
            if not lines:
                return "ok restore unchanged"
            if not all(NFT_LINE.fullmatch(x) for x in lines):
                raise Refused("internal")
            # All slots in one transaction, as in change().
            if run([NFT, "-f", "-"], "\n".join(lines) + "\n").returncode != 0:
                raise Refused("apply")
            killed = 0
            for slot, uid, profile in moved:
                killed += kill(uid)[0]
                log(f"netctl restore slot={slot} uid={uid} to={profile}")
            return f"ok restore slots={len(moved)} killed={killed}"


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
            save()
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
            if parts == ["describe"]:
                # ensure_ascii keeps the line to printable ASCII.
                return "ok describe " + json.dumps(CFG["describe"], separators=(",", ":"))
            if parts == ["restore"]:
                return restore()
            if parts[0] == "get" and len(parts) == 2 and TOKEN.fullmatch(parts[1]):
                slot = parts[1]
                if slot not in CFG["slots"]:
                    raise Refused("slot")
                uid = CFG["slots"][slot]
                now = [p for p, u in members().items() if uid in u]
                log(f"netctl get slot={slot}")
                return f"ok get slot={slot} uid={uid} profile={','.join(now) or 'none'}"
            if parts[0] == "set" and len(parts) in (3, 4) and all(TOKEN.fullmatch(p) for p in parts[1:3]):
                slot, profile = parts[1:3]
                digest = parts[3] if len(parts) == 4 else None
                if digest is not None and not DIGEST.fullmatch(digest):
                    raise Refused("usage")
                if slot not in CFG["slots"]:
                    raise Refused("slot")
                if profile not in CFG["profiles"]:
                    raise Refused("profile")
                # The harness read the profile from `describe` and shows it to a
                # person. A rebuild that changed what the profile opens makes the
                # digest differ, and nothing is applied.
                if digest is not None and digest != CFG["digests"][profile]:
                    raise Refused("changed")
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

      # Asks the helper to apply the recorded profiles again. Root may connect to
      # the socket, and the answer is checked, so a refused restore fails the
      # unit and shows in `systemctl status`.
      restoreScript = pkgs.writeShellApplication {
        name = "permafrost-netctl-restore";
        runtimeInputs = [ pkgs.socat ];
        text = ''
          reply=$(printf 'restore\n' | socat -t 30 - UNIX-CONNECT:${socketPath})
          echo "$reply"
          [[ $reply == "ok "* ]]
        '';
      };

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

          # The verb picks the helper. The three helpers check the grammar again.
          # The net helper serves one connection after the other, so a caller may
          # wait for those in front of it; a wipe may take long. socat waits this
          # long for the answer.
          case ''${cmd%% *} in
            wipe | stopjobs)
              sock=${slots.sockets.slotctl}
              patience=130
              ;;
            blocked)
              sock=${slots.sockets.blocked}
              patience=30
              ;;
            *)
              sock=${socketPath}
              patience=30
              ;;
          esac
          reply=$(printf '%s\n' "$cmd" | socat -t "$patience" - "UNIX-CONNECT:$sock" 2>/dev/null) || reply=""
          reply=''${reply%%$'\n'*}

          # The length is checked apart: a bounded repeat of thousands in a regular
          # expression makes the matcher take a hundred megabytes and seconds.
          ok='^ok [ -~]*$'
          err='^err ([2-9]) [a-z]+( [a-z]+)?$'
          if (( ''${#reply} <= 8000 )) && [[ $reply =~ $ok ]]; then
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

        systemd = {
          sockets.permafrost-netctl = {
            wantedBy = [ "sockets.target" ];
            listenStreams = [ socketPath ];
            socketConfig = {
              SocketUser = "root";
              SocketGroup = "netctl";
              SocketMode = "0660";
              Accept = false;
            };
          };

          services.permafrost-netctl = {
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
              # The recorded profiles, kept when the helper exits after ten idle
              # seconds. Owned by the dynamic user, so nothing else writes it.
              RuntimeDirectory = "permafrost-netctl";
              RuntimeDirectoryMode = "0700";
              RuntimeDirectoryPreserve = true;
            };
          };

          # A reload of nftables.service deletes the table and loads it again, and
          # every slot is then in the default profile. This puts them back.
          # partOf carries a restart of nftables, ReloadPropagatedFrom a reload.
          services.permafrost-netctl-restore = {
            description = "Put the factory slots back on their network profile after nftables loads";
            wantedBy = [ "multi-user.target" ];
            after = [
              "nftables.service"
              "permafrost-netctl.socket"
            ];
            requires = [ "permafrost-netctl.socket" ];
            partOf = [ "nftables.service" ];
            unitConfig.ReloadPropagatedFrom = [ "nftables.service" ];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              ExecStart = "${restoreScript}/bin/permafrost-netctl-restore";
              ExecReload = "${restoreScript}/bin/permafrost-netctl-restore";
            };
          };
        };
      };
    };
}
