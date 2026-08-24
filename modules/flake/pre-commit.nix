{ inputs, ... }:
{
  imports = [ inputs.pre-commit-hooks.flakeModule ];

  # This module owns .pre-commit-config.yaml, which is a tracked symlink into the
  # store. devenv.nix deliberately declares no git hooks so the two shells do not
  # churn that file between them — see the note in CLAUDE.md §2.
  perSystem = _: {
    pre-commit.settings.hooks = {
      nixfmt.enable = true;
      deadnix.enable = true;
      statix.enable = true;
    };
  };
}
