{ inputs, ... }:
{
  # Declares `flake.modules.<class>.<name>` as
  # `lazyAttrsOf (lazyAttrsOf deferredModule)`, which is what lets every file
  # under modules/ contribute its own entry and have them merge rather than
  # collide. Without this import each definition would be a conflicting
  # assignment to one freeform `flake.modules` attribute.
  #
  # It also stamps `_class` on each module, so a homeManager entry cannot be
  # imported into a NixOS configuration by accident.
  imports = [ inputs.flake-parts.flakeModules.modules ];
}
