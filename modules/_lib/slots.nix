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
}
