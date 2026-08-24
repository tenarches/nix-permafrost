{
  # Browser automation, for whichever harness reaches for it.
  #
  # playwright-test, not playwright: the latter is playwright-core, a bare node
  # library directory with no bin/, so installing it puts nothing on PATH. This
  # is the package that carries the `playwright` command, and its wrapper
  # defaults PLAYWRIGHT_BROWSERS_PATH to the Nix-built browsers — which matters
  # here, because the fallback is upstream's own download: an unpatched binary
  # that will not run on NixOS, fetched into a home that is discarded at
  # shutdown anyway.
  #
  # The browsers are ~2.1GiB, but /nix/store reaches the guest over virtiofs
  # from the host, so that is one copy on the host either way.
  flake.modules.nixos.harness-browser =
    { pkgs, ... }:
    {
      environment.systemPackages = [ pkgs.playwright-test ];
    };
}
