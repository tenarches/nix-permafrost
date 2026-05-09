{ inputs, ... }:

_: prev: {
  inherit (inputs.devenv.packages.${prev.system}) devenv;
}
