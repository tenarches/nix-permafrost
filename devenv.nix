{ pkgs, ... }:

{
  # Interactive shell for this repo. Its presence is also what makes devenv's
  # native activation fire on `cd` (the hook walks up looking for devenv.nix),
  # so a trusted checkout — `devenv allow` once — gets these tools without
  # `nix develop` or an .envrc.
  #
  # Mirrors devShells.default in flake.nix. That devShell is deliberately kept:
  # it is what `nix flake check` and the linting command in CLAUDE.md use.
  packages = [
    # Secrets handling, matching modules/secrets.nix
    pkgs.sops
    pkgs.age

    # Host-side virtiofs backends for the `nix run .#<agent>` launchers
    pkgs.virtiofsd

    # The three pre-commit linters, available directly for ad-hoc runs
    pkgs.nixfmt
    pkgs.deadnix
    pkgs.statix
  ];

  # No git-hooks.hooks here on purpose. The flake's pre-commit-hooks module owns
  # .pre-commit-config.yaml, which is a tracked symlink into the store; if devenv
  # also declared hooks, that file would be rewritten depending on which shell
  # was entered last and show up as a spurious diff.
}
