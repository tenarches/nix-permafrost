{
  inputs,
  pkgs,
  lib,
  config,
  ...
}:

{
  imports = [
    inputs.microvm.nixosModules.microvm
    inputs.home-manager.nixosModules.home-manager
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

    "/nix/.rw-store" = {
      device = "tmpfs";
      fsType = "tmpfs";
      options = [ "size=2G" ];
      neededForBoot = true;
    };

    # Agent user configuration
    # Agent's home is ephemeral tmpfs — nothing persists
    "/home/agent" = {
      device = "none";
      fsType = "tmpfs";
      options = [
        "size=512M"
        "mode=700"
        "uid=1000"
        "gid=100"
      ];
      neededForBoot = true;
    };
  };

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
    "L+ /home/agent/.agents - - - - /mnt/persist/.agents"
    "L+ /home/agent/workspace - - - - /mnt/persist/workspace"
    "d /home/agent/.ssh 0700 agent users - -"
    "d /home/agent/.config 0700 agent users - -"
    "d /home/agent/.local 0700 agent users - -"
    "d /home/agent/.local/share 0700 agent users - -"
    "d /home/agent/.local/share/nvim 0700 agent users - -"
    "d /home/agent/.bv-logic 0700 agent users - -"
  ];

  # Essential packages for agent operation, terminal persistence, and GUI support
  environment.systemPackages = with pkgs; [
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
  environment.loginShellInit = ''
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

  # Enable autologin on the serial console for nix run ergonomics
  services.getty.autologinUser = "agent";

  # SSH Configuration for JIT MicroVM lifecycle
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "prohibit-password";
    };
    authorizedKeysCommand = "${pkgs.writeShellScript "get-ssh-keys" ''
      # Only return keys for valid agent users
      if [ "$1" = "agent" ] || [ "$1" = "root" ]; then
        if [ -f /run/credentials/sshd.service/ssh.authorized_keys.base64 ]; then
          ${pkgs.coreutils}/bin/base64 -d /run/credentials/sshd.service/ssh.authorized_keys.base64
        fi
      fi
    ''}";
    authorizedKeysCommandUser = "root";
  };

  systemd.services.sshd.serviceConfig.LoadCredential = [
    "ssh.authorized_keys.base64"
  ];

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

  system.stateVersion = "25.11";
}
