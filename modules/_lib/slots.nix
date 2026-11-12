# Naming and ids for the factory slot accounts.
#
# Not a module — imported directly by the guest modules and by the checks, so
# the account names, the uids and the defaults have one definition. `cfg` is
# `config.permafrost.slots`.
rec {
  # The defaults that both sides of the workspaces share read: the guest options
  # (guest/slots.nix) and the host module take them from here, so a default
  # cannot move on one side only.
  defaults = {
    count = 16;
    userPrefix = "f-slot";
    hostPath = "/var/lib/permafrost-workspaces";
    readerPath = "/srv/permafrost-workspaces";
    readerGroup = "permafrost-ws";
    # Above systemd's container range (0x70000000) and below 2^31, so no
    # passwd entry on a host has one of these numbers.
    hostIdBase = 2000000000;
  };

  # Slot numbers run from 1, so the account of slot 3 is f-slot3.
  name = cfg: n: "${cfg.userPrefix}${toString n}";

  # The gid is the uid, and the group has the name of the user.
  uid = cfg: n: cfg.uidBase + n;

  # Every slot name, 1..count.
  names = cfg: builtins.genList (i: name cfg (i + 1)) cfg.count;

  # The workspaces share. One virtiofs share carries the workspaces of every
  # slot: the tag names it on both launch paths, `shareMount` is where the
  # guest mounts it, and `shareRoot` is its parent, which only root may enter.
  shareTag = "factory_ws";
  shareRoot = "/mnt/factory";
  shareMount = "${shareRoot}/workspaces";

  # What a slot owns on the host: slot n writes as this id (the map of
  # `virtiofsdArgs`). No passwd entry of a host has such a number.
  hostUid = cfg: n: cfg.workspaces.hostIdBase + n;

  # The host group that reads the workspaces. It is the first id of the range,
  # so it is not the group of any slot.
  readerGid = cfg: cfg.workspaces.hostIdBase;

  # The flags of the one virtiofsd that serves the share, for both launch
  # paths. Each element is one word with no shell metacharacter, so the runner
  # can quote the list as it is and the fleet unit can join it with spaces.
  #
  # The ids of the slots map one to one to host ids above 2 * 10^9. Every other
  # guest id is refused when it creates a file or changes an owner: only a
  # slot makes files in the share, and the host never gets a file of guest root
  # or of agent. Reads and writes of files that exist are not refused, because
  # virtiofsd acts with its own rights once the guest kernel has allowed the
  # call. The map cannot be used with --posix-acl.
  virtiofsdArgs =
    cfg:
    let
      first = cfg.uidBase + 1;
      after = cfg.uidBase + cfg.count + 1;
      rules = flag: [
        flag
        "map:${toString first}:${toString (cfg.workspaces.hostIdBase + 1)}:${toString cfg.count}"
        flag
        "forbid-guest:0:${toString first}"
        flag
        "forbid-guest:${toString after}:${toString (4294967295 - after)}"
      ];
    in
    rules "--translate-uid" ++ rules "--translate-gid";

  # The mounts of the workspaces share in the guest, as `fileSystems` entries:
  # the options of the share, and one bind mount for each slot, from its part of
  # the share into its home. Here and not in the module, so that the VM check,
  # whose nodes replace `fileSystems` with `virtualisation.fileSystems`, mounts
  # exactly these.
  #
  # nosuid and nodev on both. No nosymfollow: a link in a workspace has to work
  # for its slot (node_modules/.bin, the result link of nix build, worktrees),
  # and the host reader mounts the same files with it (host/workspaces.nix). The
  # home is on its own volume and the share has to be there first, so each bind
  # mount depends on both.
  workspaceMounts =
    cfg:
    {
      ${shareMount}.options = [
        "nosuid"
        "nodev"
      ];
    }
    // builtins.listToAttrs (
      builtins.map (name: {
        name = "${cfg.homeRoot}/${name}/workspaces";
        value = {
          device = "${shareMount}/${name}";
          fsType = "none";
          options = [
            "bind"
            "nosuid"
            "nodev"
          ];
          depends = [
            shareMount
            cfg.homeRoot
          ];
        };
      }) (names cfg)
    );

  # The read-only view of the host tree for the reader, as a `fileSystems`
  # entry for host/workspaces.nix (`cfg` is `permafrost.host.workspaces`). Here
  # for the same reason as `workspaceMounts`: the VM check mounts exactly this.
  #
  # nosymfollow: the reader runs with host rights and a slot makes the links, so
  # a link to /etc/passwd must not open it. ro: the one write barrier, see the
  # header of host/workspaces.nix. A bind mount may need a remount to take ro
  # and the other flags; the ro-check unit looks at what the kernel shows.
  readerMount = cfg: {
    ${cfg.readerPath} = {
      device = cfg.path;
      fsType = "none";
      options = [
        "bind"
        "ro"
        "nosymfollow"
        "nosuid"
        "nodev"
      ];
    };
  };

  # The shell function that guards the host tree of the workspaces share, for
  # the runner (_pkgs/runner.nix) and for the check that runs it on a symlink.
  #
  # The guest can rename a symlink that a slot made into the top level of the
  # share, because virtiofsd acts with host rights, and the runner is root. So
  # each directory is checked before `install` touches it: it must not be a
  # symlink, and an existing one must be a directory that is not reached
  # through a link of its own (a link higher up is the business of the host).
  # There is no chown -R and no chmod -R, ever: the content of a slot is not
  # trusted.
  safeDir = coreutils: ''
    safe_dir() {
      if [ -L "$1" ]; then
        echo "Error: $1 is a symlink; not touching the workspaces tree." >&2
        exit 1
      fi
      if [ -e "$1" ]; then
        if [ "$(${coreutils}/bin/stat -c %F "$1")" != directory ]; then
          echo "Error: $1 is not a directory; not touching the workspaces tree." >&2
          exit 1
        fi
        PARENT=$(${coreutils}/bin/realpath -e "$(${coreutils}/bin/dirname "$1")")
        if [ "$(${coreutils}/bin/realpath -e "$1")" != "$PARENT/$(${coreutils}/bin/basename "$1")" ]; then
          echo "Error: $1 does not resolve to itself; not touching the workspaces tree." >&2
          exit 1
        fi
      fi
    }
  '';

  # The one account that may change the network profile of a slot, through the
  # helper of guest/netctl.nix. The egress table (guest/network-egress.nix)
  # confines it as well, so both modules need the number.
  netctl = {
    name = "netctl";
    uid = 1002;
  };

  # The name of a profile inside nft identifiers: the profile names allow `-`,
  # nft identifiers do not.
  profileId = profile: builtins.replaceStrings [ "-" ] [ "_" ] profile;

  # The nft set that holds the uids of the slots on one profile.
  uidSet = profile: "uids_${profileId profile}";
}
