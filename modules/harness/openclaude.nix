{
  # openclaude — an independent coding-agent CLI, not an accessory to
  # claude-code. It rode along in harness/claude.nix because it is a Claude Code
  # fork and the two were packaged together, but it keeps its own state under
  # its own names, so it gets its own module like every other harness.
  #
  # The package is built here from npm rather than coming from llm-agents.nix:
  # see modules/_pkgs/openclaude.nix for the update procedure.
  flake.modules.nixos.harness-openclaude =
    { pkgs, ... }:
    {
      environment.systemPackages = [ (pkgs.callPackage ../_pkgs/openclaude.nix { }) ];

      # The same two-part shape as claude-code's: a settings directory plus one
      # JSON file next to it holding auth. Neither persisted while this was
      # folded into harness/claude.nix, which shares only the `.claude` pair —
      # so a login here did not survive a boot.
      permafrost.shares = [
        {
          host = ".openclaude";
          guest = ".openclaude";
        }
        {
          # ~/.openclaude.json is a file, and a share mounts a directory, so it
          # is carried inside one and linked out — the same trick
          # harness/claude.nix uses for ~/.claude.json.
          host = ".config/openclaude";
          guest = ".openclaude-config";
          link = ".openclaude.json";
        }
      ];
    };
}
