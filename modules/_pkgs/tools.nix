# Host-side helpers: discovery, reclamation, and the ssh_config for reaching the
# guest. All three read the guest's own configuration rather than a copy of it,
# so none of them can drift from what was actually built.
{ pkgs, nixos }:

let
  inherit (nixos.config.permafrost) identity;
in
{
  # Reclaim ephemeral image directories left behind by a guest that is no longer
  # built. ExecStopPost handles the normal case and preStart bounds a live guest
  # to one stale image set, but a renamed or deleted guest's directory has
  # nothing left to clean it — that is the only unbounded source of orphans.
  gc = pkgs.writeShellScriptBin "permafrost-gc" ''
    set -euo pipefail
    ROOT="/var/lib/permafrost"

    [ -d "$ROOT" ] || { echo "Nothing to collect: $ROOT does not exist."; exit 0; }

    reclaimed=0
    for dir in "$ROOT"/*; do
      [ -d "$dir" ] || continue
      name=$(${pkgs.coreutils}/bin/basename "$dir")
      if systemctl is-active --quiet "microvm-$name"; then
        echo "keep    $name (running)"
        continue
      fi
      size=$(${pkgs.coreutils}/bin/du -sh --apparent-size "$dir" 2>/dev/null | ${pkgs.coreutils}/bin/cut -f1)
      used=$(${pkgs.coreutils}/bin/du -sh "$dir" 2>/dev/null | ${pkgs.coreutils}/bin/cut -f1)
      ${pkgs.coreutils}/bin/rm -rf "$dir"
      echo "reclaim $name (apparent $size, on-disk $used)"
      reclaimed=$((reclaimed + 1))
    done
    echo "Reclaimed $reclaimed directories."
  '';

  # Discovery: the guest's address, and whether it is actually running.
  # machinectl is not usable here — microvm.nix's own runner.nix notes that NSS
  # resolution works for containers but not VMs, so machined would list the VM
  # without its address. The IP is static, so read it from the guest's config.
  status = pkgs.writeShellScriptBin "permafrost-status" ''
    set -euo pipefail
    printf '%-13s %-16s %-5s %-18s %s\n' GUEST IP CID TAP STATE
    state=$(systemctl is-active "microvm-${identity.name}" 2>/dev/null || true)
    printf '%-13s %-16s %-5s %-18s %s\n' \
      "${identity.name}" "${identity.ip}" "${toString identity.vsockCid}" \
      "microvm-${identity.tapId}" "$state"
  '';

  # The host-side ssh_config for reaching the guest, derived from the same
  # identity the guest is built from.
  #
  # The catch-all block needs no maintenance, because everything in it is
  # structural rather than per-guest: the 192.168.33.0/24 subnet, `agent` as the
  # only login user, host keys regenerated on every boot, and one forwarding
  # socket.
  #
  # Takes the runtime directory holding the agent socket, so the path is
  # resolved for whoever will actually run ssh rather than assuming a uid.
  # The runner calls this with the launching user's own directory and installs
  # the result; running it by hand prints the same thing for the current user.
  ssh-config = pkgs.writeShellScriptBin "permafrost-ssh-config" ''
    RUNTIME_DIR="''${1:-/run/user/$(id -u)}"

    ${pkgs.gnused}/bin/sed "s|@SOCK@|$RUNTIME_DIR/permafrost-agent.sock|" <<'EOF'
    # Managed by nix-permafrost. Rewritten from the guest's own configuration
    # every time it is launched, so edits here are lost — change the flake
    # instead.
    #
    # The socket below is the permafrost agent, carrying the agentic key alone.
    # Never point it at the personal agent: the guest would gain the use of your
    # personal key for the life of the connection.

    Host 192.168.33.* ${identity.name}
      User agent
      ForwardAgent @SOCK@

      # The guest is rebuilt from scratch on every boot and presents a new host
      # key each time, so a persistent known_hosts entry refuses the second
      # launch. Scoped to it only — the global default still applies elsewhere.
      StrictHostKeyChecking no
      UserKnownHostsFile /dev/null

      ServerAliveInterval 150
      ServerAliveCountMax 2

    Host ${identity.name}
      Hostname ${identity.ip}
    EOF
  '';
}
