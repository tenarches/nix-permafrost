{
  inputs,
  pkgs,
  lib,
  config,
  ...
}:

let
  # Per-VM host-side directory holding this guest's ephemeral disk images.
  # Keyed on hostName, which inventory.nix guarantees is unique per agent.
  stateDir = "/var/lib/permafrost/${config.networking.hostName}";
  img = name: "${stateDir}/${name}.img";

  # Every writable path in the guest lives on a sparse, disk-backed volume that is
  # destroyed and recreated on each boot. Nothing writable is RAM-backed except /,
  # which microvm.nix mounts as a tmpfs at 50% of guest memory.
  volumes = [
    {
      # Overlay upperdir for the Nix store. ext4 rather than btrfs: overlayfs upper
      # semantics are best-tested on ext4/xfs, and CoW is a poor fit underneath an
      # overlay. mounts.nix sets neededForBoot automatically because this mountPoint
      # matches microvm.writableStoreOverlay, so it is mounted in stage 1.
      image = img "rw-store";
      mountPoint = "/nix/.rw-store";
      fsType = "ext4";
      label = "rw-store";
      size = 32768;
      autoCreate = true;
    }
    {
      # The agent's whole home, workspace included. btrfs with zstd because the guest
      # writes into a sparse host image: without TRIM passthrough deleted files never
      # return blocks, so compression roughly halves how fast the image grows on
      # source trees, node_modules and build output.
      image = img "home";
      mountPoint = "/home/agent";
      fsType = "btrfs";
      label = "agent-home";
      size = 32768;
      autoCreate = true;
    }
    {
      # Separate from home so root-owned and agent-owned temp files do not collide on
      # a 0700 home, and so a runaway build fills /tmp rather than the workspace.
      # Nix builds lean on TMPDIR heavily.
      image = img "tmp";
      mountPoint = "/tmp";
      fsType = "ext4";
      label = "tmp";
      size = 16384;
      autoCreate = true;
    }
    {
      # Raw and unformatted. createVolumesScript has no "swap" fsType, so preStart
      # truncates this and writes the swap header host-side instead — mkswap writes
      # only a header (7ms) whereas swapDevices[].size would dd the whole 4 GiB
      # through virtio-blk on every boot.
      image = img "swap";
      mountPoint = null;
      size = 4096;
      autoCreate = false;
    }
  ];

  # Derive the swap device letter with microvm.nix's own helper rather than
  # hardcoding it, matching on mountPoint == null so it survives reordering above.
  inherit (import "${inputs.microvm}/lib" { inherit lib; }) withDriveLetters;
  swapVolume =
    lib.findFirst (v: v.mountPoint == null) (throw "agent-base: no raw swap volume")
      (withDriveLetters {
        inherit volumes;
        inherit (config.microvm) storeOnDisk;
      });
in

{
  imports = [
    inputs.microvm.nixosModules.microvm
    inputs.home-manager.nixosModules.home-manager
    # The NixOS stylix module is what injects stylix.targets.* into the Home
    # Manager option tree below, so the HM-only targets (tmux, nixvim) are
    # reachable without importing stylix.homeModules.stylix separately.
    inputs.stylix.nixosModules.stylix
    ./theme.nix
    ./agent-environment.nix
  ];
  # Shared base module for all agent VMs
  microvm = {
    hypervisor = lib.mkDefault "cloud-hypervisor";
    vsock.cid = lib.mkDefault 10;
    vcpu = lib.mkDefault 4;
    mem = lib.mkDefault 8194; # Avoid 4096MB hang in certain hypervisors (e.g. cloud-hypervisor)

    # The Nix store from the host is shared read-only into the guest.
    shares = [
      {
        source = "/nix/store";
        mountPoint = "/nix/.ro-store";
        tag = "ro-store";
        proto = "virtiofs";
      }
    ];

    # Ephemeral state via microvm.writableStoreOverlay
    # This gives the guest a writable overlay atop the host's read-only Nix store share.
    writableStoreOverlay = "/nix/.rw-store";

    inherit volumes;

    # Ephemerality: destroy the previous boot's images before createVolumesScript
    # recreates them. Runs before that script in microvm-run, where PATH is not yet
    # set up, so absolute store paths are required.
    #
    # The swap volume is autoCreate = false, so it is created here and given its
    # header directly. mkswap warns on 0644, hence the chmod; the file stays sparse.
    preStart = ''
      ${pkgs.coreutils}/bin/mkdir -p ${stateDir}
      ${pkgs.coreutils}/bin/rm -f ${stateDir}/*.img
      ${pkgs.coreutils}/bin/truncate -s ${toString swapVolume.size}M ${swapVolume.image}
      ${pkgs.coreutils}/bin/chmod 0600 ${swapVolume.image}
      ${pkgs.util-linux}/bin/mkswap ${swapVolume.image}
    '';

    # Holistic Credential Injection for Cloud-Hypervisor
    # Since cloud-hypervisor does not support SMBIOS-based credential injection (standard in microvm.nix),
    # we use the --platform oem_string mechanism to pass secrets. This script reads the
    # host-side credential files and formats them into a single --platform flag.
    extraArgsScript =
      let
        cfg = config.microvm;
        isCLH = cfg.hypervisor == "cloud-hypervisor";
        hasCreds = cfg.credentialFiles != { };
      in
      lib.mkIf (isCLH && hasCreds) (
        let
          credEntries = lib.mapAttrsToList (name: path: { inherit name path; }) cfg.credentialFiles;

          readCredsScript = lib.concatMapStrings (
            { name, path }:
            ''
              if [ ! -r "${path}" ]; then
                echo "agent-base: cannot read '${path}' for credential '${name}'" >&2
                exit 1
              fi
              _val=$(cat "${path}")
              _oem_parts="''${_oem_parts:+''${_oem_parts},}io.systemd.credential:${name}=''${_val}"
            ''
          ) credEntries;
        in
        ''
          _oem_parts=""
          ${readCredsScript}
          printf -- '--platform oem_string=[%s]' "$_oem_parts"
        ''
      );
  };

  fileSystems = {
    "/nix/.ro-store" = {
      fsType = "virtiofs";
      neededForBoot = true;
    };

    # Mount itself is generated by microvm's mounts.nix from microvm.volumes above
    # (device /dev/disk/by-label/rw-store, neededForBoot). Only extra options here.
    # discard returns freed blocks to the sparse host image as the store is GC'd.
    "/nix/.rw-store".options = [ "discard" ];

    # Agent's home is an ephemeral disk volume — nothing persists across a boot.
    # Mount is generated from microvm.volumes; ownership comes from stock NixOS,
    # since isNormalUser implies createHome = true and homeMode = "700", and
    # update-users-groups chowns the mounted directory during activation.
    "/home/agent".options = [
      "compress=zstd:1"
      "discard"
    ];

    "/tmp".options = [ "discard" ];
  };

  # No `size` and no `randomEncryption`: preStart already wrote the header, so the
  # generated mkswap-*.service body is empty and systemd simply swapons the device.
  swapDevices = [ { device = "/dev/vd${swapVolume.letter}"; } ];

  # Network setup
  networking = {
    useDHCP = false;
    useNetworkd = true;
    nameservers = [
      "10.0.7.15"
      "10.0.7.16"
      "1.1.1.1"
    ];
  };

  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    trusted-users = [
      "root"
      "agent"
    ];
    substituters = [
      "https://cache.nixos.org/"
      "https://devenv.cachix.org"
    ];
    trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw="
    ];
  };

  # Agent user configuration
  users.mutableUsers = false;
  users.users.agent = {
    isNormalUser = true;
    uid = 1000;
    home = "/home/agent";
    hashedPassword = ""; # No password
    extraGroups = [
      "wheel"
      "video"
      "render"
      "users"
      "systemd-journal"
    ]; # For sudo, GPU, and logs
  };

  # Enable passwordless sudo for the wheel group
  security.sudo.wheelNeedsPassword = false;

  programs.tmux = {
    enable = true;
    extraConfig = ''
      set -g extended-keys on
      set -g extended-keys-format csi-u
    '';
  };

  # Automatically symlink persistent mounts from /mnt/persist to home
  # This avoids the "empty directory" issue caused by mounting into a tmpfs
  systemd.tmpfiles.rules = [
    # The home volume mounts as root:root 0755 and must be chowned to the agent.
    # users.users.agent.createHome does chown+chmod, but it runs during activation,
    # which is not ordered after local-fs.target — it chowns the pre-mount directory
    # and the volume then mounts over it. btrfs has no uid/gid mount options (that is
    # a tmpfs-only trick), so fix it here: systemd-tmpfiles-setup is After
    # local-fs.target and part of sysinit.target, so this lands after the mount and
    # before home-manager-agent.service, which is After basic.target and
    # home-agent.mount. Without it, HM activation fails on mkdir ~/.cache.
    "d /home/agent 0700 agent users - -"
    "L+ /home/agent/.agents - - - - /mnt/persist/.agents"
    # workspace is now a plain directory on the ephemeral home volume, not a host
    # share — so BV_PROJECT_ROOT and orchestrator.ts keep resolving unchanged.
    "d /home/agent/workspace 0700 agent users - -"
    "d /home/agent/.ssh 0700 agent users - -"
    "d /home/agent/.config 0700 agent users - -"
    "d /home/agent/.local 0700 agent users - -"
    "d /home/agent/.local/share 0700 agent users - -"
    "d /home/agent/.local/share/nvim 0700 agent users - -"
    "d /home/agent/.bv-logic 0700 agent users - -"
  ];

  environment = {
    # Essential packages for agent operation, terminal persistence, and GUI support
    systemPackages = with pkgs; [
      git
      bash
      coreutils
      curl
      gnutar
      gzip
      xz
      tmux
      jq
      # GUI Support libraries (Mesa/GL)
      mesa
      libGL
      vulkan-loader
      # Wayland/X11 client libraries for Electron
      wayland
      libX11
      libXcursor
      libXrandr
      libXi
    ];

    # Helper to set WAYLAND_DISPLAY from kernel command line
    loginShellInit = ''
      if [[ -z "$WAYLAND_DISPLAY" || "$WAYLAND_DISPLAY" == "@@HOST_WAYLAND_DISPLAY@@" ]]; then
        # Try to find it in /proc/cmdline (e.g. wayland_display=wayland-1)
        PROBED_WL=$(cat /proc/cmdline | tr ' ' '\n' | grep '^wayland_display=' | cut -d= -f2 || true)
        if [ -z "$PROBED_WL" ]; then
          # Fallback to searching the mount point
          PROBED_WL=$(ls /run/user/1000/wayland-* 2>/dev/null | head -n1 | xargs basename 2>/dev/null || true)
        fi
        if [ -n "$PROBED_WL" ]; then
          export WAYLAND_DISPLAY="$PROBED_WL"
        else
          export WAYLAND_DISPLAY="wayland-0"
        fi
      fi
    '';

  };

  # Enable autologin on the serial console for nix run ergonomics
  services.getty.autologinUser = "agent";

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "prohibit-password";
      AuthorizedKeysFile = "/etc/ssh/authorized_keys.d/%u .ssh/authorized_keys";
    };
  };

  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    extraSpecialArgs = { inherit inputs; };
    users.agent = {
      imports = [
        inputs.nixvim.homeModules.nixvim
        ./programs/nixvim.nix
      ];
    };
  };

  system.stateVersion = "26.05";
}
