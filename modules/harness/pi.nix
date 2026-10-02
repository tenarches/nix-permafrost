{ inputs, ... }:
{
  # pi. It speaks MCP natively; servers are added in ~/.pi/agent/mcp.json,
  # which lives in the shared `.pi` directory.
  flake.modules.nixos.harness-pi =
    { pkgs, lib, ... }:
    let
      models = import ../_lib/models.nix { inherit pkgs lib; };
      agents = inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system};
    in
    {
      environment.systemPackages = [ agents.pi ];

      permafrost.shares = [
        # Gemini OAuth tokens, written by `pi /login`.
        {
          host = ".pi";
          guest = ".pi";
        }
      ];

      # A store symlink, which is fine here: pi reads this file and never
      # rewrites it. Contrast harness/dsh.nix, which has to copy.
      home-manager.users.agent.home.file.".pi/agent/models.json".source = models.piModelsJson;
    };
}
