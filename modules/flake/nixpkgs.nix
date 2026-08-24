{ inputs, ... }:

let
  overlays = [
    # Centralized Python MCP overrides
    (import ../../overlays/python-mcp.nix)
    # MCP server packages — evaluated against patched pkgs
    inputs.mcp-servers-nix.overlays.default
  ];

  config.allowUnfree = true;
in
{
  # The runner scripts and the guest need the same package set. Overriding the
  # perSystem `pkgs` argument gets the overlays into both without a second
  # `import inputs.nixpkgs` and the extra nixpkgs evaluation that would cost on
  # every `nix build`.
  perSystem =
    { system, ... }:
    {
      _module.args.pkgs = import inputs.nixpkgs { inherit system overlays config; };
    };

  # The NixOS-side half, imported by both the host and the guest.
  # hostPlatform is deliberately not set here: it belongs to whichever
  # configuration is being built, which is the thing that knows its system.
  flake.modules.nixos.nixpkgs = {
    nixpkgs = { inherit overlays config; };
  };
}
