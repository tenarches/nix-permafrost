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
      # The inference API root for pi and dsh. It lives here with the MCP
      # address because both are served by the one gateway edge.
      options.permafrost.inference.baseUrl = lib.mkOption {
        type = lib.types.str;
        default = "https://inference.home.lan/v1";
        example = "https://gateway.example/v1";
        description = ''
          OpenAI-compatible API root of the LAN inference gateway (Bifrost),
          `/v1` included. pi's `baseUrl`, dsh's `baseURL` and the dsh model
          refresh all read it. The endpoint is https under the internal CA,
          which guest/ca-trust.nix makes the guest trust.
        '';
      };

      options.permafrost.mcp.gatewayUrl = lib.mkOption {
        type = lib.types.str;
        default = "https://inference.home.lan/mcp";
        example = "https://gateway.example/mcp";
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
