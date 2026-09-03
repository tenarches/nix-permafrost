{
  # Everything the guest is regardless of how it was launched: its disks, its
  # user, its network, its shell environment. What differs between the two
  # launch paths is only `microvm.shares`, which lives in launch-runner.nix and
  # launch-fleet.nix.
  flake.modules.nixos.guest-base =
    {
      inputs,
      pkgs,
      lib,
      config,
      ...
    }:

    let
      cfg = config.permafrost.identity;

      # Per-VM host-side directory holding this guest's ephemeral disk images.
      stateDir = "/var/lib/permafrost/${cfg.name}";
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
          size = 102400; # 100 GiB
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
          size = 51200; # 50 GiB
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
          size = 16384;
          autoCreate = false;
        }
      ];

      # Derive the swap device letter with microvm.nix's own helper rather than
      # hardcoding it, matching on mountPoint == null so it survives reordering above.
      inherit (import "${inputs.microvm}/lib" { inherit lib; }) withDriveLetters;
      swapVolume =
        lib.findFirst (v: v.mountPoint == null) (throw "guest-base: no raw swap volume")
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
        # Manager option tree, so the HM-only targets (tmux, nixvim) are
        # reachable without importing stylix.homeModules.stylix separately.
        inputs.stylix.nixosModules.stylix
      ];

      microvm = {
        hypervisor = lib.mkDefault "cloud-hypervisor";
        vcpu = lib.mkDefault 4;
        mem = lib.mkDefault 8194; # Avoid 4096MB hang in certain hypervisors (e.g. cloud-hypervisor)

        vsock.cid = cfg.vsockCid;

        interfaces = [
          {
            type = "tap";
            id = "microvm-${cfg.tapId}";
            inherit (cfg) mac;
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
        #
        # Nothing populates microvm.credentialFiles today, so this is inert. It is
        # kept because it is the only credential route cloud-hypervisor offers and
        # rediscovering it would be expensive.
        extraArgsScript =
          let
            mcfg = config.microvm;
            isCLH = mcfg.hypervisor == "cloud-hypervisor";
            hasCreds = mcfg.credentialFiles != { };
          in
          lib.mkIf (isCLH && hasCreds) (
            let
              credEntries = lib.mapAttrsToList (name: path: { inherit name path; }) mcfg.credentialFiles;

              readCredsScript = lib.concatMapStrings (
                { name, path }:
                ''
                  if [ ! -r "${path}" ]; then
                    echo "guest-base: cannot read '${path}' for credential '${name}'" >&2
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

      networking = {
        hostName = cfg.name;
        useDHCP = false;
        useNetworkd = true;
        inherit (cfg) nameservers;
      };

      # Matched on `en*` rather than pinned to eth0, because cloud-hypervisor's
      # virtio-net interface does not reliably come up under that name. Both
      # launch paths share this, so the guest addresses itself identically
      # whether it was started by the runner or by the host's fleet unit.
      systemd.network.networks."10-lan" = {
        matchConfig.Name = "en*";
        address = [ "${cfg.ip}/24" ];
        gateway = [ cfg.gateway ];
        dns = cfg.nameservers;
        networkConfig.IPv6AcceptRA = false;
      };

      nix.settings = {
        experimental-features = [
          "nix-command"
          "flakes"
        ];
        # When free space in the store drops below min-free during a build,
        # the daemon garbage-collects until max-free bytes are free, keeping
        # the rw overlay from ever hitting 100% again. max-free is bounded
        # because the default (infinite) would collect every unrooted path on
        # the first trigger and force mass re-downloads.
        #
        # No auto-optimise-store here: microvm.nix asserts it cannot work
        # with writableStoreOverlay (hard links cannot cross the overlay
        # boundary). Dedup happens on the host, whose store is the read-only
        # lower layer.
        min-free = 5368709120; # 5 GiB
        max-free = 21474836480; # 20 GiB
        # root only. A nix trusted user is root-equivalent by construction —
        # the daemon runs as root and honours per-invocation `substituters`,
        # `post-build-hook`, `sandbox = false` and friends from anyone on this
        # list. Leaving `agent` here would have made removing sudo below
        # decorative. Ordinary `nix build`/`develop`/`run` against the
        # substituters declared here are unaffected.
        trusted-users = [ "root" ];
        substituters = [
          "https://cache.nixos.org/"
          "https://devenv.cachix.org"
        ];
        trusted-public-keys = [
          "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
          "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw="
        ];
      };

      # Agent user configuration.
      #
      # The agent has no route to root in the guest. That is the point of the
      # three settings below plus `trusted-users` above: the VM is the
      # isolation boundary, and an agent that can become root inside it can
      # read anything delivered to any service in it — the dsh TLS key, the
      # forwarded agent socket, every harness credential.
      users = {
        mutableUsers = false;

        # The assertion this waives is "neither the root account nor any wheel
        # user has a password or SSH authorized key", and it is accurate:
        # after the settings here, nothing does. That is the intended shape
        # rather than an accident. Interactive access is the serial console,
        # which autologins as the agent, and ssh as the agent with the
        # launching user's harvested keys. Root is reachable only by
        # certificate, and only when a CA has been configured — see
        # modules/guest/ssh-ca.nix.
        #
        # Being locked out costs nothing here that it would cost on a real
        # machine: the guest is rebuilt from scratch on every boot, so the
        # recovery for a guest you cannot log into is to stop it and launch
        # again.
        allowNoPasswordLogin = true;

        users.agent = {
          isNormalUser = true;
          uid = 1000;
          home = "/home/agent";

          # Locked, not empty. "" is a valid empty password that `su` accepts;
          # only "!" refuses. Removing sudo while leaving this would have moved
          # the door rather than closed it.
          hashedPassword = "!";

          # No wheel. video/render are the GPU, systemd-journal is log access,
          # and both survive independently of sudo.
          extraGroups = [
            "video"
            "render"
            "users"
            "systemd-journal"
          ];
        };
      };

      # Removes the setuid wrapper, not merely the rule — the whole module is
      # gated on this. `su` comes from shadow and is wrapped separately, which
      # is why the password above has to be locked in the same breath.
      security.sudo.enable = false;

      # ~/.agents is the one share that is not a harness's own: the skills and
      # instructions every harness reads.
      permafrost.shares = [
        {
          host = ".agents";
          guest = ".agents";
        }
      ];

      # Directories the guest needs before Home Manager activation runs. The
      # share symlinks themselves are generated in guest/shares.nix.
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
        # workspace is a plain directory on the ephemeral home volume, not a host
        # share: nothing an agent produces here reaches the host.
        "d /home/agent/workspace 0700 agent users - -"
        "d /home/agent/.ssh 0700 agent users - -"
        "d /home/agent/.config 0700 agent users - -"
        "d /home/agent/.local 0700 agent users - -"
        "d /home/agent/.local/share 0700 agent users - -"
        "d /home/agent/.local/share/nvim 0700 agent users - -"
      ];

      environment = {
        # Essential packages for agent operation, terminal persistence, and GUI support.
        # The harness CLIs themselves come from modules/harness/*.nix.
        systemPackages = with pkgs; [
          git
          bash
          coreutils
          curl
          gnutar
          gzip
          xz
          # tmux is configured entirely in Home Manager (guest/home/tmux.nix) so
          # that stylix, whose tmux target is HM-only, owns its colours. The
          # binary stays here for root.
          tmux
          jq
          # An interpreter the agents reach for often enough that its absence
          # is a recurring interruption — a one-off script, a bit of parsing,
          # a quick calculation. Nearly free: harness/mcp.nix already drags the
          # same derivation in for the two python MCP servers, so this adds the
          # profile entries and not the interpreter. Measured at 61 KiB on the
          # toplevel closure.
          python3
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
          # Display transport, unconditionally rather than only when
          # permafrost.gui is on: `waypipe ssh agent@<ip> <app>` needs no
          # virtio-gpu and no compositor in the guest, only this binary on both
          # ends.
          waypipe
          xdg-utils
        ];

        # Toolkit hints for any GUI app, set unconditionally because both display
        # transports need them. Without NIXOS_OZONE_WL an Electron build falls back
        # to the X11 ozone backend and dies on "Missing X server or $DISPLAY", even
        # when a perfectly good Wayland socket is waiting for it.
        #
        # WAYLAND_DISPLAY and DISPLAY are deliberately absent: waypipe exports its
        # own WAYLAND_DISPLAY for the process it launches, so a global one naming a
        # socket that may not exist would break it. guest/graphics.nix adds them
        # when the in-guest proxy is actually running.
        variables = {
          XDG_SESSION_TYPE = "wayland"; # Electron reads this
          QT_QPA_PLATFORM = "wayland";
          GDK_BACKEND = "wayland";
          SDL_VIDEODRIVER = "wayland";
          CLUTTER_BACKEND = "wayland";
          NIXOS_OZONE_WL = "1";
          # No GPU is passed through; rendering is Mesa llvmpipe either way.
          LIBGL_ALWAYS_SOFTWARE = "1";
          WLR_RENDERER_ALLOW_SOFTWARE = "1";
        };
      };

      # Agent VMs routinely fetch prebuilt binaries: language toolchains, LSP
      # servers, and application "hosts" downloaded at first run. Those are foreign
      # ELFs whose interpreter is /lib64/ld-linux-x86-64.so.2, a path NixOS does not
      # have, so without nix-ld they fail at exec with a bare
      # "No such file or directory" that says nothing about the real cause.
      #
      # libraries already defaults to a base set derived from the systemd and nix
      # closures (glibc included); these three are the common additions for
      # dynamically linked application binaries.
      programs.nix-ld = {
        enable = true;
        libraries = with pkgs; [
          stdenv.cc.cc.lib
          zlib
          openssl
        ];
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

      system.stateVersion = "26.05";
    };
}
