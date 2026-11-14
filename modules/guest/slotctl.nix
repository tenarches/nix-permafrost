{ lib, ... }:

let
  slots = import ../_lib/slots.nix;
in
{
  # The root helper behind the `wipe` and `stopjobs` verbs of the `netctl` login
  # (netctl.nix has the wrapper and the grammar).
  #
  # A factory in pi-durable owns one slot. When it is deleted the slot must be
  # empty before another factory gets it, and when its network access narrows,
  # what runs on the wider profile must stop first. Both are things that the
  # slot cannot be trusted to do for itself: a wipe that runs as the slot runs
  # inside the environment that the slot's untrusted text controls (rc files, a
  # nested subvolume that the slot can create and cannot remove, a user manager
  # that starts its units again). So root does it.
  #
  # The grammar is `wipe <slot>` and `stopjobs <slot>`, and the slot is looked up
  # in a table that is written at build time. No verb takes a path, a uid or a
  # host. The helper lives behind its own socket (`root:netctl 0660`, the same
  # mode as the net helper), and its own unit, so the net helper keeps
  # CAP_NET_ADMIN and nothing else, and a bug here cannot touch nft.
  #
  # `stopjobs <slot>` ends every process of the uid, whatever protocol it
  # speaks and whatever session it is in, and removes nothing. A narrowing of
  # the network profile uses it after `set`: `set` closes the TCP connections,
  # and a UDP sender or a process with a socket in a state that the table does
  # not see keeps running until this.
  #
  # `wipe <slot>` does, in this order, each step logged with the tag
  # `permafrost-slotctl`, and each named in the answer when it fails:
  #
  #   kill      SIGKILL for the units of the uid (the user manager and its
  #             scopes, so nothing starts the processes again), then for every
  #             process of the uid that is left, including setsid daemons, until
  #             none is left (10 seconds); SysV IPC of the uid is removed
  #   files     the home (dotfiles too, nothing of another file system) and the
  #             contents of the workspaces directory, which is the mount of the
  #             share, so the ids are the ones the slot used. A nested btrfs
  #             subvolume is emptied and removed like a directory
  #   tmp       the files of the uid in /tmp, /var/tmp and /dev/shm
  #   units     the user manager and the runtime directory stop, and the linger
  #             file goes
  #   ssh       the ssh state of the home (known_hosts, control sockets, keys)
  #             is gone; it is inside the home, so this step is the proof
  #   skeleton  systemd-tmpfiles makes `tmp` and `work` again, the profile goes
  #             back to the default (the `set` of the net helper), and the home
  #             must hold exactly the skeleton, empty, with the owner and the
  #             mode of the module
  #   home      the unit of `permafrost.slotctl.homeUnits` for the slot (the
  #             Home Manager activation) restarts and writes the dotfiles of
  #             the module again; a slot with no unit keeps the empty skeleton
  #
  # The wipe is idempotent: it can run again after a crash or a failed step.
  # `gen` in the answer counts the wipes of the slot that ended well, and is kept
  # in /var/lib/permafrost-slotctl. A second request for a slot that a wipe or a
  # `stopjobs` is working on is `err 7 busy`; another slot is served at the same
  # time.
  #
  # What this costs. The `netctl` certificate can wipe or stop any slot of the
  # guest, not only the slots of one harness. That is no new authority when one
  # guest serves one harness, which already holds the login of every slot. Two
  # harnesses on one guest need two guests, or their own `netctl` role.
  #
  # The unit runs as root, because it has to remove files of another uid in
  # every directory it names. Its capability set is the seven that it needs
  # (CAP_KILL, CAP_DAC_OVERRIDE, CAP_DAC_READ_SEARCH, CAP_FOWNER, CAP_CHOWN for
  # tmpfiles, CAP_SETUID and CAP_SETGID to remove the SysV objects of the slot as
  # the slot), it has no inet socket, and the paths it works on
  # come from the table. Not closed: it is root, and a bug in it is a bug of
  # root. The size of the helper (one Python file, input of two verbs and a
  # table) is the limit.
  #
  # The established TCP connections of the slot are not closed with `ss -K` here:
  # every socket belongs to a process that is dead by then, and the kernel closes
  # it.
  flake.modules.nixos.guest-slotctl =
    {
      config,
      pkgs,
      utils,
      ...
    }:

    let
      cfg = config.permafrost.slotctl;
      slotCfg = config.permafrost.slots;
      netCfg = config.permafrost.network;
      systemd = config.systemd.package;

      table = pkgs.writeText "permafrost-slotctl.json" (
        builtins.toJSON {
          systemctl = "${systemd}/bin/systemctl";
          tmpfiles = "${systemd}/bin/systemd-tmpfiles";
          ipcrm = "${pkgs.util-linux}/bin/ipcrm";
          find = "${pkgs.findutils}/bin/find";
          netctlSocket = slots.sockets.netctl;
          default = netCfg.defaultProfile;
          tmpDirs = [
            "/tmp"
            "/var/tmp"
            "/dev/shm"
          ];
          lingerDir = "/var/lib/systemd/linger";
          stateDir = "/var/lib/permafrost-slotctl";
          inherit (cfg) homeUnits;
          slots = lib.listToAttrs (
            map (
              n:
              lib.nameValuePair (slots.name slotCfg n) {
                uid = slots.uid slotCfg n;
                home = "${slotCfg.homeRoot}/${slots.name slotCfg n}";
                workspaces = slotCfg.workspaces.enable;
              }
            ) (lib.range 1 slotCfg.count)
          );
        }
      );

      helper = pkgs.writers.writePython3Bin "permafrost-slotctl-helper" { flakeIgnore = [ "E501" ]; } ''
        import json
        import os
        import re
        import signal
        import socket
        import stat
        import subprocess
        import sys
        import threading
        import time

        with open("${table}") as f:
            CFG = json.load(f)

        LINE = re.compile(r"[a-z0-9 -]{1,64}")
        TOKEN = re.compile(r"[a-z][a-z0-9-]{0,30}")
        CODES = {"usage": 2, "slot": 3, "internal": 6, "busy": 7, "step": 8}
        # The root inode of a btrfs subvolume. A directory with another device
        # number than its parent is a mount or a subvolume, and only the second
        # is ours to empty.
        SUBVOLUME_INO = 256

        LOCKS = {name: threading.Lock() for name in CFG["slots"]}
        ACTIVE = [0]
        ACTIVE_LOCK = threading.Lock()


        class Refused(Exception):
            def __init__(self, word, text=None):
                super().__init__(word)
                self.word = word
                self.text = text or word


        class Step(Exception):
            """A step of a wipe failed. The word is the name of the step."""

            def __init__(self, step, why=""):
                super().__init__(step)
                self.step = step
                self.why = why


        def log(msg):
            print(msg, flush=True)


        def run(argv, timeout=30):
            return subprocess.run(
                argv, capture_output=True, text=True, shell=False, timeout=timeout, check=False,
            )


        def pids_of(uid):
            """The live processes that have the uid as real, effective, saved or fs id."""
            found = []
            for entry in os.listdir("/proc"):
                if not entry.isdigit():
                    continue
                try:
                    with open(f"/proc/{entry}/status") as f:
                        ids = []
                        zombie = False
                        for line in f:
                            if line.startswith("State:"):
                                zombie = "Z" in line.split(":", 1)[1].split()[0]
                            elif line.startswith("Uid:"):
                                ids = [int(x) for x in line.split()[1:5]]
                                break
                except (OSError, ValueError):
                    continue
                # A zombie holds no resource but its entry, and its parent or init
                # reaps it.
                if uid in ids and not zombie:
                    found.append(int(entry))
            return found


        def kill_all(uid):
            """End every process of the uid. Returns how many there were."""
            before = pids_of(uid)
            # The units first, so that the user manager cannot start anything
            # again, and the scopes of the sessions with it.
            units = [f"user@{uid}.service", f"user-{uid}.slice"]
            run([CFG["systemctl"], "kill", "--kill-whom=all", "--signal=SIGKILL"] + units)
            deadline = time.monotonic() + 10
            while True:
                left = pids_of(uid)
                if not left:
                    break
                if time.monotonic() > deadline:
                    raise Step("kill", f"{len(left)} processes left")
                for pid in left:
                    try:
                        os.kill(pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                time.sleep(0.1)
            return len(before)


        def ipc_ids(table, id_col, uid):
            """The ids of the SysV objects of one kind that the uid owns or made."""
            ids = []
            try:
                with open(f"/proc/sysvipc/{table}") as f:
                    header = f.readline().split()
                    for line in f:
                        cols = line.split()
                        row = dict(zip(header, cols))
                        if str(uid) in (row.get("uid"), row.get("cuid")):
                            ids.append(row[id_col])
            except OSError:
                pass
            return ids


        def remove_ipc(uid):
            for table, id_col, flag in [("shm", "shmid", "-m"), ("msg", "msqid", "-q"), ("sem", "semid", "-s")]:
                for ident in ipc_ids(table, id_col, uid):
                    # Removing an object needs its owner or CAP_SYS_ADMIN, and
                    # CAP_IPC_OWNER is not enough. So the fixed command runs as the
                    # slot (no process of it is left to interfere), which takes
                    # CAP_SETUID and CAP_SETGID and not the much wider CAP_SYS_ADMIN.
                    r = subprocess.run(
                        [CFG["ipcrm"], flag, ident], capture_output=True, text=True, shell=False,
                        timeout=30, check=False, user=uid, group=uid, extra_groups=[],
                    )
                    if r.returncode != 0:
                        raise Step("kill", f"ipcrm {flag} {ident}: {r.stderr.strip()[:80]}")


        def purge_children(path, skip=()):
            """Remove everything inside a directory, and not the directory.

            Works by directory file descriptor and with no recursion: a path of any
            depth, and a name that looks like a path, cannot break it, and a link is
            removed and never followed. A directory on another device is removed only
            when it is the root of a btrfs subvolume (it is emptied, then removed
            with rmdir, which root may do to an empty subvolume). Anything else, a
            mount for example, stops the wipe: what is under it is not ours.
            Returns the number of entries removed.
            """
            removed = 0
            flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
            root = os.open(path, flags)
            # [fd, device, names to do, name in the parent, parent fd]
            frames = [[root, os.fstat(root).st_dev, [n for n in os.listdir(root) if n not in skip], None, None]]
            try:
                while frames:
                    frame = frames[-1]
                    fd, dev, names, name, parent = frame
                    if not names:
                        frames.pop()
                        os.close(fd)
                        if parent is not None:
                            os.rmdir(name, dir_fd=parent)
                            removed += 1
                        continue
                    child = names.pop()
                    st = os.lstat(child, dir_fd=fd)
                    if not stat.S_ISDIR(st.st_mode):
                        os.unlink(child, dir_fd=fd)
                        removed += 1
                        continue
                    if st.st_dev != dev and st.st_ino != SUBVOLUME_INO:
                        raise Step("files", f"{child} is a mount")
                    cfd = os.open(child, flags, dir_fd=fd)
                    frames.append([cfd, os.fstat(cfd).st_dev, os.listdir(cfd), child, fd])
            finally:
                for frame in frames:
                    os.close(frame[0])
            return removed


        def purge_owned(top, uid):
            """Remove what the uid owns below a shared directory (/tmp and the like).

            An entry at the top that the uid owns goes with everything in it. Deeper
            down, `find` removes the entries of the uid and leaves the others.
            """
            removed = 0
            try:
                names = os.listdir(top)
            except OSError:
                return 0
            for name in names:
                path = os.path.join(top, name)
                try:
                    st = os.lstat(path)
                except OSError:
                    continue
                if st.st_uid != uid:
                    continue
                if stat.S_ISDIR(st.st_mode):
                    removed += purge_children(path)
                    os.rmdir(path)
                else:
                    os.unlink(path)
                removed += 1
            r = run([CFG["find"], top, "-xdev", "-uid", str(uid), "-depth", "-print", "-delete"], timeout=60)
            removed += len(r.stdout.splitlines())
            left = run([CFG["find"], top, "-xdev", "-uid", str(uid), "-print", "-quit"], timeout=60)
            if left.stdout.strip():
                raise Step("tmp", "a file of the uid is left")
            return removed


        def netctl(line):
            s = socket.socket(socket.AF_UNIX)
            s.settimeout(30)
            try:
                s.connect(CFG["netctlSocket"])
                s.sendall((line + "\n").encode("ascii"))
                buf = b""
                while b"\n" not in buf:
                    chunk = s.recv(4096)
                    if not chunk:
                        break
                    buf += chunk
            finally:
                s.close()
            return buf.decode("ascii", "replace").strip()


        def bump(name):
            os.makedirs(CFG["stateDir"], mode=0o700, exist_ok=True)
            path = os.path.join(CFG["stateDir"], name + ".gen")
            try:
                with open(path) as f:
                    gen = int(f.read().strip() or "0")
            except (OSError, ValueError):
                gen = 0
            gen += 1
            with open(path + ".new", "w") as f:
                f.write(str(gen))
            os.replace(path + ".new", path)
            return gen


        def skeleton(name, slot):
            home = slot["home"]
            uid = slot["uid"]
            r = run([CFG["tmpfiles"], "--create", f"--prefix={home}"])
            if r.returncode != 0:
                raise Step("skeleton", "tmpfiles")
            reply = netctl(f"set {name} {CFG['default']}")
            if not reply.startswith("ok set "):
                raise Step("profile", reply[:40])
            expect = {"tmp", "work"} | ({"workspaces"} if slot["workspaces"] else set())
            seen = set(os.listdir(home))
            if seen != expect:
                raise Step("skeleton", f"home holds {sorted(seen)}")
            st = os.lstat(home)
            if (st.st_uid, stat.S_IMODE(st.st_mode)) != (uid, 0o700):
                raise Step("skeleton", "home owner or mode")
            for child in sorted(expect):
                if os.listdir(os.path.join(home, child)):
                    raise Step("skeleton", f"{child} is not empty")
            if pids_of(uid):
                raise Step("skeleton", "a process came back")


        def wipe(name, slot):
            uid = slot["uid"]
            home = slot["home"]
            log(f"slotctl wipe slot={name} uid={uid} start")
            killed = kill_all(uid)
            remove_ipc(uid)
            log(f"slotctl wipe slot={name} step=kill killed={killed}")
            removed = 0
            try:
                skip = {"workspaces"} if slot["workspaces"] else set()
                removed += purge_children(home, skip)
                if slot["workspaces"]:
                    removed += purge_children(os.path.join(home, "workspaces"))
            except OSError as e:
                raise Step("files", type(e).__name__)
            log(f"slotctl wipe slot={name} step=files removed={removed}")
            try:
                tmp = sum(purge_owned(top, uid) for top in CFG["tmpDirs"])
            except OSError as e:
                raise Step("tmp", type(e).__name__)
            log(f"slotctl wipe slot={name} step=tmp removed={tmp}")
            run([CFG["systemctl"], "stop", f"user@{uid}.service", f"user-runtime-dir@{uid}.service", f"user-{uid}.slice"])
            run([CFG["systemctl"], "reset-failed", f"user@{uid}.service"])
            try:
                os.unlink(os.path.join(CFG["lingerDir"], name))
            except FileNotFoundError:
                pass
            except OSError:
                raise Step("units", "linger")
            if pids_of(uid):
                raise Step("units", "a process came back")
            log(f"slotctl wipe slot={name} step=units")
            if os.path.lexists(os.path.join(home, ".ssh")):
                raise Step("ssh", ".ssh is there")
            log(f"slotctl wipe slot={name} step=ssh")
            skeleton(name, slot)
            # The home is proved empty first; then its activation unit writes
            # the files of the module again, as a boot would.
            unit = CFG["homeUnits"].get(name)
            if unit is not None:
                # 30 s: the whole wipe must answer inside the 130 s that netctl
                # waits (and the 120 s of the harness). An activation takes seconds.
                try:
                    r = run([CFG["systemctl"], "restart", unit], timeout=30)
                except subprocess.TimeoutExpired:
                    raise Step("home", "timeout")
                if r.returncode != 0:
                    raise Step("home", unit)
                log(f"slotctl wipe slot={name} step=home unit={unit}")
            gen = bump(name)
            log(f"slotctl wipe slot={name} uid={uid} gen={gen} done")
            return f"ok wipe slot={name} uid={uid} gen={gen} killed={killed} removed={removed} tmp={tmp}"


        def stopjobs(name, slot):
            uid = slot["uid"]
            killed = kill_all(uid)
            log(f"slotctl stopjobs slot={name} uid={uid} killed={killed}")
            return f"ok stopjobs slot={name} uid={uid} killed={killed}"


        def answer(line):
            if not LINE.fullmatch(line):
                raise Refused("usage")
            parts = line.split(" ")
            if len(parts) != 2 or parts[0] not in ("wipe", "stopjobs") or not TOKEN.fullmatch(parts[1]):
                raise Refused("usage")
            verb, name = parts
            if name not in CFG["slots"]:
                raise Refused("slot")
            lock = LOCKS[name]
            if not lock.acquire(blocking=False):
                log(f"slotctl busy slot={name} verb={verb}")
                raise Refused("busy")
            try:
                try:
                    return (wipe if verb == "wipe" else stopjobs)(name, CFG["slots"][name])
                except Step as e:
                    log(f"slotctl {verb} slot={name} step={e.step} failed: {e.why}")
                    raise Refused("step", f"{verb} {e.step}")
            finally:
                lock.release()


        def handle(conn):
            conn.settimeout(5)
            buf = b""
            while b"\n" not in buf and len(buf) < 256:
                chunk = conn.recv(256)
                if not chunk:
                    break
                buf += chunk
            line = buf.decode("ascii", "replace")
            conn.settimeout(None)
            try:
                if not line.endswith("\n") or line.count("\n") != 1:
                    raise Refused("usage")
                reply = answer(line[:-1])
            except Refused as e:
                reply = f"err {CODES[e.word]} {e.text}"
                log(f"slotctl reject code={CODES[e.word]} reason={e.text} input={ascii(line[:64])}")
            except Exception as e:
                reply = "err 6 internal"
                log(f"slotctl internal error {type(e).__name__} input={ascii(line[:64])}")
            conn.sendall((reply + "\n").encode("ascii"))


        def serve(conn):
            with conn:
                try:
                    handle(conn)
                except OSError as e:
                    log(f"slotctl connection error {type(e).__name__}")
                finally:
                    with ACTIVE_LOCK:
                        ACTIVE[0] -= 1


        def main():
            if os.environ.get("LISTEN_PID") != str(os.getpid()) or os.environ.get("LISTEN_FDS") != "1":
                sys.exit("slotctl: start through the socket unit")
            srv = socket.socket(fileno=3)
            srv.settimeout(10)
            while True:
                try:
                    conn, _ = srv.accept()
                except socket.timeout:
                    with ACTIVE_LOCK:
                        if ACTIVE[0] == 0:
                            return
                    continue
                with ACTIVE_LOCK:
                    ACTIVE[0] += 1
                threading.Thread(target=serve, args=(conn,), daemon=False).start()


        main()
      '';
    in
    {
      options.permafrost.slotctl = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = ''
            The root helper for `wipe` and `stopjobs` behind the `netctl` login.
            It needs `guest-netctl`, which holds the login and the wrapper, and
            the slot accounts of `guest-slots`.
          '';
        };

        homeUnits = lib.mkOption {
          type = lib.types.attrsOf lib.types.str;
          # A slot that Home Manager configures gets its activation unit back
          # after a wipe. Without it the dotfiles return only at the next boot.
          default = lib.listToAttrs (
            lib.concatMap (
              n:
              let
                name = slots.name slotCfg n;
              in
              # Home Manager escapes the user name in the unit name: f-slot1 is
              # home-manager-f\x2dslot1.service.
              lib.optional ((config.home-manager.users or { }) ? ${name}) (
                lib.nameValuePair name "home-manager-${utils.escapeSystemdPath name}.service"
              )
            ) (lib.range 1 slotCfg.count)
          );
          defaultText = lib.literalExpression ''"home-manager-<slot>.service" for each slot in home-manager.users'';
          description = ''
            For each slot, the oneshot unit that writes the files of the home
            again. The wipe restarts it after the home holds only the skeleton
            (step `home`). A slot that is not here keeps an empty home.
          '';
        };
      };

      config = lib.mkIf cfg.enable {
        systemd = {
          sockets.permafrost-slotctl = {
            wantedBy = [ "sockets.target" ];
            listenStreams = [ slots.sockets.slotctl ];
            socketConfig = {
              SocketUser = "root";
              SocketGroup = "netctl";
              SocketMode = "0660";
              Accept = false;
            };
          };

          services.permafrost-slotctl = {
            description = "Wipe and stop the processes of a factory slot";
            serviceConfig = {
              ExecStart = "${helper}/bin/permafrost-slotctl-helper";
              SyslogIdentifier = "permafrost-slotctl";
              # Root, because the files of another uid are in every directory it
              # works on. The set of capabilities is what that takes.
              CapabilityBoundingSet = [
                "CAP_KILL"
                "CAP_DAC_OVERRIDE"
                "CAP_DAC_READ_SEARCH"
                "CAP_FOWNER"
                "CAP_CHOWN"
                "CAP_SETUID"
                "CAP_SETGID"
              ];
              NoNewPrivileges = true;
              # /usr, /boot and /etc read-only. No more than that: the helper
              # writes in every home, /tmp, /var/tmp, /dev/shm, /var/lib/systemd
              # and its own state, and the bind mounts of the share are below the
              # homes.
              ProtectSystem = "full";
              ProtectKernelModules = true;
              ProtectControlGroups = true;
              # systemctl talks to the manager over a unix socket. No inet socket,
              # so a hijacked helper cannot call out.
              RestrictAddressFamilies = [ "AF_UNIX" ];
              LockPersonality = true;
              MemoryDenyWriteExecute = true;
              StateDirectory = "permafrost-slotctl";
              StateDirectoryMode = "0700";
              # A wipe of a large share takes time, and the client waits for it.
              TimeoutStopSec = 30;
            };
          };
        };
      };
    };
}
