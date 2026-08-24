{
  # MCP servers, available to every harness that knows how to speak the
  # protocol. A harness still has to be told about them — see the plugin rows in
  # harness/dsh.nix for what "mounting" one actually looks like.
  flake.modules.nixos.harness-mcp =
    { pkgs, ... }:
    {
      environment.systemPackages = [
        pkgs.context7-mcp
        pkgs.mcp-server-time
        pkgs.github-mcp-server
        pkgs.terraform-mcp-server
        pkgs.mcp-nixos
      ];
    };
}
