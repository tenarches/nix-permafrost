{
  inputs,
  config,
  lib,
  ...
}:
let
  slots = import ../_lib/slots.nix;
in
{
  # Wires every flake.modules.homeManager.agent-* entry into the guest's agent
  # user, so a new Home Manager module needs no edit here — dropping a file into
  # guest/home/ that declares itself under that prefix is the whole change.
  flake.modules.nixos.guest-home =
    # `config` here is the flake's. The guest's own is `nixos.config`.
    nixos: {
      home-manager = {
        useGlobalPkgs = true;
        useUserPackages = true;
        extraSpecialArgs = { inherit inputs; };
        users = {
          agent.imports = [
            inputs.nixvim.homeModules.nixvim
          ]
          ++ lib.attrValues (
            lib.filterAttrs (n: _: lib.hasPrefix "agent-" n) config.flake.modules.homeManager
          );
          # adurable (guest/adurable.nix) gets the shared tooling only. The other
          # agent-* modules carry the owner's SSH, crawl4ai and herdr wiring, which
          # an account that runs commands from untrusted text must not reach.
          adurable.imports = [ config.flake.modules.homeManager.agent-environment ];
        }
        # The factory slots (guest/slots.nix) get the same, for the same reason.
        // lib.genAttrs (slots.names nixos.config.permafrost.slots) (_: {
          imports = [ config.flake.modules.homeManager.agent-environment ];
        });
      };
    };
}
