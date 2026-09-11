{ inputs, ... }:

let
  config.allowUnfree = true;
in
{
  # The runner scripts and the guest need the same package set. Overriding the
  # perSystem `pkgs` argument gets the shared configuration into both without a
  # second `import inputs.nixpkgs` and the extra nixpkgs evaluation that would
  # cost on every `nix build`.
  #
  # No overlays. The two that used to be here — a Python override set and the
  # mcp-servers-nix package set — existed only to build MCP servers inside the
  # guest, and the guest no longer runs any: see harness/mcp.nix.
  perSystem =
    { system, ... }:
    {
      _module.args.pkgs = import inputs.nixpkgs { inherit system config; };
    };

  # The NixOS-side half, imported by both the host and the guest.
  # hostPlatform is deliberately not set here: it belongs to whichever
  # configuration is being built, which is the thing that knows its system.
  flake.modules.nixos.nixpkgs = {
    nixpkgs = { inherit config; };
  };
}
