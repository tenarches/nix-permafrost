{
  # Keep OpenSSH's login record where OpenSSH looks for it.
  #
  # sshd keeps its own record in /var/log/lastlog and warns twice on the first
  # login of every boot when the file is missing:
  #
  #   lastlog_openseek: Couldn't stat /var/log/lastlog: No such file or directory
  #
  # Nothing creates it here. The file is conventionally shipped by the
  # distribution, and this guest's /var is a fresh volume on every boot.
  #
  # Creating it is only half the fix, and on its own it is self-defeating.
  # NixOS pulls in lastlog2-import.service whenever any PAM service has
  # lastlog enabled (nixos/modules/security/pam.nix), to migrate the legacy
  # file into lastlog2's sqlite database. It is guarded by
  #
  #   ConditionPathExists=/var/log/lastlog
  #   ExecStartPost=mv /var/log/lastlog /var/log/lastlog.migrated
  #
  # so a tmpfiles rule alone satisfies the condition, the importer fires, and
  # the file is renamed away before sshd ever looks for it — leaving the same
  # warning plus a migration that ran for nothing. Confirmed in a live guest:
  # the created file reappeared as /var/log/lastlog.migrated, timestamped to
  # the second the importer ran.
  #
  # So turn the importer off as well. It is a one-shot upgrade migration and
  # has nothing to do in a guest whose /var is new on every boot — there has
  # never been a previous lastlog to carry forward. pam_lastlog2 keeps
  # recording logins either way; only the migration is disabled.
  #
  # mkForce because pam.nix asserts `true` unconditionally alongside the unit
  # it defines, so this is a genuine override rather than a default being
  # filled in. systemd.suppressedSystemUnits does not work here: it filters
  # only units NixOS pulls in itself, and this one also arrives through
  # systemd.packages from util-linux.
  flake.modules.nixos.guest-lastlog =
    { lib, ... }:
    {
      systemd = {
        tmpfiles.rules = [ "f /var/log/lastlog 0644 root root -" ];
        services.lastlog2-import.enable = lib.mkForce false;
      };
    };
}
