{ inputs, ... }:
{
  flake.modules.nixos.harness-crush =
    { pkgs, ... }:
    {
      environment.systemPackages = [
        inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.crush
      ];

      permafrost.shares = [
        {
          host = ".config/crush";
          guest = ".config/crush";
        }
        {
          host = ".local/share/crush";
          guest = ".local/share/crush";
        }
      ];
    };
}
