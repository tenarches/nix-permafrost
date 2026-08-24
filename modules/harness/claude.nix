{ inputs, ... }:
{
  flake.modules.nixos.harness-claude =
    { pkgs, ... }:
    {
      environment.systemPackages = [
        inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.claude-code
      ];

      permafrost.shares = [
        {
          host = ".claude";
          guest = ".claude";
        }
        {
          # Mounted under a name of its own because ~/.config is a plain
          # directory on the ephemeral home volume that other harnesses also
          # write into, so the share cannot land on top of it. The `link` then
          # puts the one file the harness actually looks for at ~/.claude.json.
          host = ".config/claude";
          guest = ".claude-config";
          link = ".claude.json";
        }
      ];
    };
}
