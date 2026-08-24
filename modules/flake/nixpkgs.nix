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
  # The runner scripts and the guest need the same package set. runners.nix used
  # to reach for it with a second `import inputs.nixpkgs`, which meant a whole
  # extra nixpkgs evaluation on every `nix build`; overriding the perSystem
  # `pkgs` argument gets the overlays in without one.
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
