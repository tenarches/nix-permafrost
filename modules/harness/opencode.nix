{ inputs, ... }:
{
  flake.modules.nixos.harness-opencode =
    { pkgs, ... }:
    {
      environment.systemPackages = [
        inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.opencode
      ];

      permafrost.shares = [
        {
          host = ".config/opencode";
          guest = ".config/opencode";
        }
      ];
    };
}
