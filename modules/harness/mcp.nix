{
  # The one MCP endpoint every harness in this guest talks to.
  #
  # There are no MCP servers in the guest any more. They live behind a gateway
  # on the private LAN, which multiplexes them onto a single streamable-http
  # endpoint — so a harness needs one address rather than a package, a store
  # path and an invocation form per server.
  #
  # This file declares the address and nothing else. Mounting it is still each
  # harness's own act: see the plugin row in harness/dsh.nix for what that looks
  # like, and note that the other harnesses read their MCP configuration from
  # host shares rather than from Nix, so pointing those at the gateway is an
  # edit on the host.
  flake.modules.nixos.harness-mcp =
    { lib, ... }:
    {
      options.permafrost.mcp.gatewayUrl = lib.mkOption {
        type = lib.types.str;
        default = "http://petunia.home.lan:8080/mcp";
        example = "http://gateway.example:8080/mcp";
        description = ''
          Address of the LAN MCP gateway, including the path it serves the
          protocol on.

          The default needs no authentication. If a gateway that does ever
          replaces it, the credential belongs in a `headers` entry on the
          harness's own row rather than in this URL — see docs/dsh.md for how
          dsh forwards one from the environment.
        '';
      };
    };
}
