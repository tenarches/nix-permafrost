#!/usr/bin/env bash
# Smoke test of the id map of the workspaces share, by hand.
#
#   scripts/mapping-smoke.sh            # sandbox namespace, as the guest runs it
#   SANDBOX=chroot scripts/mapping-smoke.sh
#
# Needs sudo (virtiofsd runs as root, as it does for the guest) and /dev/kvm.
# It is not a flake check, and it is not the real guest: it boots the initrd
# of a minimal NixOS (no root file system, no disk, no network) that mounts one
# virtiofs share, makes files in it as guest uid 2001 and as guest
# root, and powers off. Everything lives in one mktemp directory, which is
# removed at the end. No state directory of the guest is read or written.
#
# What it asks (the flags are the real ones, from modules/_lib/slots.nix):
#
# - a file of slot 1 gets the host owner 2000000001 and the group of the
#   setgid directory, 2000000000, and the modes 640 and 2750 that the umask and
#   the setgid directory give;
# - guest root cannot create a file, and cannot chown one to 0 or to an id
#   outside the slot range, and can chown one to a slot id;
# - --translate-uid with --sandbox namespace works as root (a user namespace
#   that maps only uid 0 would make every create fail).
#
# The last line is `smoke ok` when every line below the table matched.
set -euo pipefail

SANDBOX="${SANDBOX:-namespace}"
FLAKE="$(git rev-parse --show-toplevel)"
# A short path: the vhost-user socket path may not exceed 107 bytes.
WORK="$(mktemp -d /tmp/mapsmoke.XXXXXX)"
VFSD_PID=""
cleanup() {
  [ -n "$VFSD_PID" ] && sudo kill "$VFSD_PID" 2>/dev/null || true
  sudo rm -rf "$WORK"
}
trap cleanup EXIT

[ -r /dev/kvm ] && [ -w /dev/kvm ] || { echo "no access to /dev/kvm" >&2; exit 2; }
sudo -v

# The real flags and ids, as the runner and the fleet unit use them.
SLOTS_JSON="$(nix eval --json "$FLAKE#nixosConfigurations.permafrost.config.permafrost.slots")"
read -r -a FLAGS < <(nix eval --json --impure --expr "
  let
    flake = builtins.getFlake \"$FLAKE\";
    slots = import $FLAKE/modules/_lib/slots.nix;
  in
  slots.virtiofsdArgs flake.nixosConfigurations.permafrost.config.permafrost.slots
" | jq -r 'join(" ")')
BASE="$(jq -r .workspaces.hostIdBase <<<"$SLOTS_JSON")"
UIDBASE="$(jq -r .uidBase <<<"$SLOTS_JSON")"
[ "${#FLAGS[@]}" -eq 12 ] || { echo "expected 12 words of flags, got ${#FLAGS[@]}" >&2; exit 2; }

# A kernel, an initrd that runs the test as a unit, virtiofsd and qemu.
EXPR="
  let
    flake = builtins.getFlake \"$FLAKE\";
    pkgs = flake.inputs.nixpkgs.legacyPackages.x86_64-linux;
    system = flake.inputs.nixpkgs.lib.nixosSystem {
      modules = [
        {
          nixpkgs.hostPlatform = \"x86_64-linux\";
          system.stateVersion = \"26.05\";
          boot.loader.grub.enable = false;
          fileSystems.\"/\" = { device = \"none\"; fsType = \"tmpfs\"; };
          boot.initrd.availableKernelModules = [ \"virtio_pci\" \"virtiofs\" \"fuse\" ];
          boot.initrd.kernelModules = [ \"virtio_pci\" \"virtiofs\" \"fuse\" ];
          boot.initrd.systemd.services.smoke = {
            wantedBy = [ \"initrd.target\" ];
            after = [ \"systemd-modules-load.service\" ];
            path = [ pkgs.bash pkgs.coreutils pkgs.util-linux pkgs.systemd ];
            serviceConfig = {
              Type = \"oneshot\";
              StandardOutput = \"journal+console\";
              StandardError = \"journal+console\";
            };
            script = ''
              mkdir -p /ws
              mount -t virtiofs smoke /ws
              set -- $UIDBASE
              \${builtins.readFile \"$FLAKE/scripts/mapping-smoke-guest.sh\"}
              systemctl poweroff --force
            '';
          };
          boot.kernelParams = [ \"console=ttyS0\" \"panic=-1\" ];
        }
      ];
    };
  in
  {
    kernel = system.config.system.build.kernel;
    initrd = system.config.system.build.initialRamdisk;
    inherit (pkgs) virtiofsd;
    qemu = pkgs.qemu_kvm;
  }
"
build() { nix build --no-link --print-out-paths --impure --expr "($EXPR).$1"; }
KERNEL="$(build kernel)"
INITRD="$(build initrd)"
VIRTIOFSD="$(build virtiofsd)"
QEMU="$(build qemu)"

# The tree as the runner makes it (modules/_pkgs/runner.nix).
SHARE="$WORK/share"
sudo install -d -m 0750 -o 0 -g "$BASE" "$SHARE"
sudo install -d -m 2750 -o $((BASE + 1)) -g "$BASE" "$SHARE/f-slot1"

# The log is the user's, so the redirect is not under sudo on purpose.
echo "virtiofsd: sandbox $SANDBOX, flags ${FLAGS[*]}"
sudo "$VIRTIOFSD/bin/virtiofsd" --socket-path "$WORK/vfs.sock" --socket-group "$(id -gn)" \
  --shared-dir "$SHARE" --sandbox "$SANDBOX" "${FLAGS[@]}" >"$WORK/virtiofsd.log" 2>&1 &
VFSD_PID=$!
for _ in $(seq 1 50); do
  [ -S "$WORK/vfs.sock" ] && break
  sleep 0.1
done
[ -S "$WORK/vfs.sock" ] || { cat "$WORK/virtiofsd.log" >&2; echo "virtiofsd did not start" >&2; exit 1; }

# The guest powers itself off, and the script does not wait for that: the
# marker line is the end of the test, and qemu is stopped after it.
"$QEMU/bin/qemu-system-x86_64" -enable-kvm -m 512M -nographic -no-reboot \
  -kernel "$KERNEL/bzImage" -initrd "$INITRD/initrd" \
  -append "console=ttyS0 panic=-1" \
  -object memory-backend-memfd,id=mem,size=512M,share=on -numa node,memdev=mem \
  -chardev "socket,id=vfs,path=$WORK/vfs.sock" \
  -device vhost-user-fs-pci,chardev=vfs,tag=smoke \
  >"$WORK/guest.log" 2>&1 &
QEMU_PID=$!
for _ in $(seq 1 600); do
  grep -aq 'SMOKE done' "$WORK/guest.log" && break
  kill -0 "$QEMU_PID" 2>/dev/null || break
  sleep 0.2
done
kill "$QEMU_PID" 2>/dev/null || true
wait "$QEMU_PID" 2>/dev/null || true

echo "--- guest"
sed -n 's/.*\(SMOKE .*\)/\1/p' "$WORK/guest.log" >"$WORK/results.txt"
[ -s "$WORK/results.txt" ] || { tail -n 40 "$WORK/guest.log"; echo "the guest printed no result" >&2; exit 1; }
cat "$WORK/results.txt"
echo "--- host (owner:group mode name)"
sudo find "$SHARE/f-slot1" -mindepth 1 -printf '%U:%G %m %P\n' | sort -k3 | tee "$WORK/host.txt"
echo "--- virtiofsd log"
cat "$WORK/virtiofsd.log"

# Expectations: guest results first, then the table of the host.
fail=0
want() {
  if ! grep -qF -- "$1" "$2"; then
    echo "MISSING: $1" >&2
    fail=1
  fi
}
want "SMOKE slot1-create ok" "$WORK/results.txt"
want "SMOKE root-create refused" "$WORK/results.txt"
want "SMOKE root-chown-0 refused" "$WORK/results.txt"
want "SMOKE root-chown-out-of-range refused" "$WORK/results.txt"
want "SMOKE root-chown-slot2 ok" "$WORK/results.txt"
want "$((BASE + 1)):$BASE 2750 d" "$WORK/host.txt"
want "$((BASE + 1)):$BASE 2750 d/sub" "$WORK/host.txt"
want "$((BASE + 1)):$BASE 640 f" "$WORK/host.txt"
want "$((BASE + 1)):$BASE 640 d/sub/g" "$WORK/host.txt"
want "$((BASE + 2)):$BASE 640 chowned" "$WORK/host.txt"
if grep -q ' rootfile' "$WORK/host.txt"; then
  echo "UNEXPECTED: guest root made a file" >&2
  fail=1
fi
if [ "$fail" -ne 0 ]; then
  echo "smoke FAILED" >&2
  exit 1
fi
echo "smoke ok"
