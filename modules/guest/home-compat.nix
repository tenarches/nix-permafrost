{
  flake.modules.nixos.guest-home-compat =
    _:

    {
      # Site-specific, and expected to be temporary. An agent session records the
      # absolute paths it was started from, so a session opened on the host under
      # /home/ddukes looks for those files at the same path inside the guest and
      # finds nothing — the agent's home here is /home/agent. The symlink makes both
      # spellings resolve to the same tree.
      #
      # `/` is a tmpfs in the guest, so this costs nothing and is recreated on
      # every boot. Delete this file once sessions are portable.
      systemd.tmpfiles.rules = [
        "L+ /home/ddukes - - - - /home/agent"
      ];
    };
}
