{
  # The JIT launch path: `nix run .#permafrost`.
  #
  # Everything host-side is spun up on demand by the runner script and torn down
  # with the unit's RuntimeDirectory, so every share names a socket under
  # /run/microvm-<name>/ and every source is a placeholder — virtiofsd is already
  # listening on the socket by the time cloud-hypervisor connects, so the source
  # string is never resolved as a path.
  flake.modules.nixos.launch-runner =
    {
      inputs,
      pkgs,
      lib,
      config,
      ...
    }:
    let
      shareLib = import ../_lib/shares.nix;
      cfg = config.permafrost;
      runtimeDir = "/run/microvm-${cfg.identity.name}";
    in
    {
      # microvm.cloud-hypervisor.package defaults to
      # pkgs.cloud-hypervisor-graphics — Spectrum's fork, the only build that
      # speaks vhost-user-gpu — once graphics are on. That attribute comes from
      # microvm.nix's own overlay, which this wraps with the fixups it currently
      # needs; see the comment in that file.
      #
      # Conditional, and it has to be: the first of the three overlays pins
      # pkgs.cloud-hypervisor itself to 51.0, so applying them with graphics off
      # would mean building the plain hypervisor from source on every launch
      # instead of taking the cached build nixpkgs already has.
      nixpkgs.overlays = lib.optionals cfg.gui (
        import ../../overlays/cloud-hypervisor-graphics.nix {
          microvmOverlay = inputs.microvm.overlay;
        }
      );

      microvm = {
        # Host half of the GUI path: microvm.nix's cloud-hypervisor preStart
        # launches `crosvm device gpu` against this socket and the invoking
        # session's compositor. The upstream default is a *relative* path,
        # resolved against the runner's cwd, so pin it into the unit's
        # RuntimeDirectory.
        graphics = lib.optionalAttrs cfg.gui {
          enable = true;
          socket = "${runtimeDir}/gpu.sock";
          # Pinned: must match the fork's vhost-user dialect. See the
          # nixpkgs-crosvm comment in flake.nix.
          crosvmPackage = import ../_pkgs/crosvm-graphics.nix {
            cpkgs = inputs.nixpkgs-crosvm.legacyPackages.${pkgs.stdenv.hostPlatform.system};
          };
        };

        shares = [
          {
            tag = "ro-store";
            proto = "virtiofs";
            source = "/nix/store";
            mountPoint = "/nix/.ro-store";
            socket = "${runtimeDir}/ro-store.sock";
          }
          {
            # Public halves harvested from the launching user's ssh agent, so a
            # guest rebuilt from scratch on every boot still admits whoever
            # started it. Runner-only: the fleet path has no agent to ask.
            tag = "ssh_keys";
            proto = "virtiofs";
            source = "host-managed-virtiofsd-at-ssh";
            mountPoint = "/etc/ssh/authorized_keys.d";
            socket = "${runtimeDir}/ssh.sock";
          }
          {
            # A TLS certificate for the web UI, issued from Vault by the runner
            # at launch. Empty when there was no token or Vault said no, which
            # is how the guest decides to self-sign instead — see
            # harness/dsh.nix. Runner-only for the same reason as the keys
            # above: the fleet path has nobody to ask for one.
            #
            # Under /run rather than /mnt: this is per-boot credential
            # material, not persistence, and /mnt/persist means a host share
            # that outlives the guest.
            tag = "vault_tls";
            proto = "virtiofs";
            source = "host-managed-virtiofsd-at-vault-tls";
            mountPoint = "/run/vault-tls";
            socket = "${runtimeDir}/vault-tls.sock";
          }
        ]
        ++ map (s: {
          tag = shareLib.tag s;
          proto = "virtiofs";
          source = "host-managed-virtiofsd-at-${s.host}";
          mountPoint = "/mnt/persist/${s.guest}";
          socket = "${runtimeDir}/${shareLib.tag s}.sock";
        }) cfg.shares;
      };
    };
}
