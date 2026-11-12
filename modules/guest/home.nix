{
  inputs,
  config,
  lib,
  ...
}:
{
  # Wires every flake.modules.homeManager.agent-* entry into the guest's agent
  # user, so a new Home Manager module needs no edit here — dropping a file into
  # guest/home/ that declares itself under that prefix is the whole change.
  flake.modules.nixos.guest-home = {
    home-manager = {
      useGlobalPkgs = true;
      useUserPackages = true;
      extraSpecialArgs = { inherit inputs; };
      users.agent.imports = [
        inputs.nixvim.homeModules.nixvim
      ]
      ++ lib.attrValues (
        lib.filterAttrs (n: _: lib.hasPrefix "agent-" n) config.flake.modules.homeManager
      );
      # adurable (guest/adurable.nix) gets the shared tooling only. The other
      # agent-* modules carry the owner's SSH, crawl4ai and herdr wiring, which
      # an account that runs commands from untrusted text must not reach.
      users.adurable.imports = [ config.flake.modules.homeManager.agent-environment ];
    };
  };
}
