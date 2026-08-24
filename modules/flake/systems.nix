_: {
  # mkFlake is called with the import-tree result as its only argument, so there
  # is no attrset left in flake.nix to hold this. It has to live in a module
  # file, and its absence is silent: every system-scoped output simply vanishes.
  systems = [ "x86_64-linux" ];
}
