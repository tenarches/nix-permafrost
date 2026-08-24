{ inputs, ... }:
{
  # pi, and mcporter alongside it: `mcporter` is how pi is pointed at MCP
  # servers, so its config directory is shared even though the two are separate
  # binaries.
  flake.modules.nixos.harness-pi =
    { pkgs, lib, ... }:
    let
      models = import ../_lib/models.nix { inherit pkgs lib; };
      agents = inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system};
    in
    {
      environment.systemPackages = [
        agents.pi
        agents.mcporter
      ];

      permafrost.shares = [
        # Gemini OAuth tokens, written by `pi /login`.
        {
          host = ".pi";
          guest = ".pi";
        }
        {
          host = ".mcporter";
          guest = ".mcporter";
        }
      ];

      # A store symlink, which is fine here: pi reads this file and never
      # rewrites it. Contrast harness/dsh.nix, which has to copy.
      home-manager.users.agent.home.file.".pi/agent/models.json".source = models.piModelsJson;
    };
}
