{
  # herdr's agent integrations, wired to the three harnesses that have one.
  #
  # Without these, herdr reads agent state by scraping the rendered screen.
  # With them, opencode and pi report idle/working/blocked directly, and all
  # three report a native session id — which is what lets herdr put a pane back
  # into the same conversation after its server restarts.
  #
  # Claude Code is deliberately wired through /etc rather than ~/.claude. The
  # upstream installer merges a SessionStart entry into ~/.claude/settings.json,
  # but ~/.claude here is a virtiofs share of the *host's* directory
  # (harness/claude.nix), so that merge would rewrite the launching user's own
  # Claude settings from inside the guest. Claude Code merges hooks across
  # settings sources rather than letting one replace another, so an entry in the
  # guest's own /etc reaches guest sessions and touches nothing on the host.
  #
  # The cost is cosmetic: `herdr integration status` reports the Claude hook as
  # "not installed" because it looks for HERDR_INTEGRATION_VERSION in
  # ~/.claude/hooks/herdr-agent-state.sh specifically. The hook still runs.
  #
  # pi and opencode have no equivalent — the extension and plugin files *are*
  # the mechanism — so those two store symlinks do land in host-shared
  # directories and outlive the guest. They are inert there: every payload
  # returns early unless HERDR_ENV is 1 and a herdr socket is on the
  # environment. This follows harness/pi.nix, which already places models.json
  # into that same shared ~/.pi/agent.
  flake.modules.nixos.guest-herdr-integrations =
    { pkgs, ... }:
    let
      integrations = pkgs.callPackage ../_pkgs/herdr-integrations.nix { };
    in
    {
      # Shape copied from what `herdr integration install claude` writes, with
      # the command pointed at the wrapper rather than a path under ~/.claude.
      environment.etc."claude-code/managed-settings.json".source =
        (pkgs.formats.json { }).generate "claude-managed-settings.json"
          {
            hooks.SessionStart = [
              {
                matcher = "*";
                hooks = [
                  {
                    type = "command";
                    command = "${integrations}/bin/herdr-agent-state session";
                    timeout = 10;
                  }
                ];
              }
            ];
          };

      home-manager.users.agent.home.file = {
        ".pi/agent/extensions/herdr-agent-state.ts".source =
          "${integrations}/share/pi/herdr-agent-state.ts";
        ".config/opencode/plugins/herdr-agent-state.js".source =
          "${integrations}/share/opencode/herdr-agent-state.js";
      };
    };
}
