{
  # Keep OpenSSH's login record where OpenSSH looks for it.
  #
  # sshd keeps its own record in /var/log/lastlog and warns twice on the first
  # login of every boot when the file is missing:
  #
  #   lastlog_openseek: Couldn't stat /var/log/lastlog: No such file or directory
  #
  # Something does create it: systemd's own var.conf ships
  #
  #   f /var/log/lastlog 0664 root utmp -
  #
  # What removed it is lastlog2-import.service, which NixOS pulls in whenever
  # any PAM service has lastlog enabled (nixos/modules/security/pam.nix), to
  # migrate the legacy file into lastlog2's sqlite database. It is guarded by
  #
  #   ConditionPathExists=/var/log/lastlog
  #   ExecStartPost=mv /var/log/lastlog /var/log/lastlog.migrated
  #
  # so the condition is met on every boot, the importer fires, and the file is
  # renamed away before sshd ever looks for it. Confirmed in a live guest: it
  # reappeared as /var/log/lastlog.migrated, timestamped to the second the
  # importer ran.
  #
  # So masking the importer is the entire fix. It is a one-shot upgrade
  # migration and has nothing to do in a guest whose /var is new on every boot
  # — there has never been a previous lastlog to carry forward. pam_lastlog2
  # keeps recording logins either way; only the migration is disabled.
  #
  # Deliberately *no* tmpfiles rule of our own. One was added here first, and
  # it collided: systemd.tmpfiles.rules lands in 00-nixos.conf, which sorts
  # ahead of var.conf, so ours won and systemd's was discarded with
  #
  #   /etc/tmpfiles.d/var.conf:17: Duplicate line for path "/var/log/lastlog",
  #     ignoring.
  #
  # twice per boot — the original warning traded for a new one, and the file
  # created 0644 root:root instead of 0664 root:utmp.
  #
  # mkForce because pam.nix asserts `true` unconditionally alongside the unit
  # it defines, so this is a genuine override rather than a default being
  # filled in. systemd.suppressedSystemUnits does not work here: it filters
  # only units NixOS pulls in itself, and this one also arrives through
  # systemd.packages from util-linux.
  flake.modules.nixos.guest-lastlog =
    { lib, ... }:
    {
      systemd.services.lastlog2-import.enable = lib.mkForce false;
    };
}
