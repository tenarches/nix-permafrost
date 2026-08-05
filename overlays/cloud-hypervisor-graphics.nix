{ microvmOverlay }:

# Makes microvm.nix's `cloud-hypervisor-graphics` build against current nixpkgs.
#
# The graphics fork lives in Spectrum; microvm.nix's overlay builds it as
# `super.cloud-hypervisor.overrideAttrs` plus Spectrum's virtio-gpu patches.
# Those patches are written against cloud-hypervisor 51.0 (vhost 0.14.0 /
# vhost-user-backend 0.20.0), while nixpkgs has moved to 53.0 (0.16.0 / 0.22.0),
# so `0001-build-use-local-vhost.patch` no longer applies. microvm.nix `main`
# pins the same Spectrum revision, so this is upstream lag, not a stale input.
#
# Returns the three overlays in the order they must be applied: pin the base
# package, let microvm.nix derive the fork from it, then correct the vendored
# dependency hash. Only guests with `gui = true` apply these — no other VM
# builds cloud-hypervisor from source.
#
# Remove once Spectrum's patches rebase onto the vhost 0.16 API.
[
  (final: prev: {
    cloud-hypervisor = prev.cloud-hypervisor.overrideAttrs (_: {
      version = "51.0";
      src = final.fetchFromGitHub {
        owner = "cloud-hypervisor";
        repo = "cloud-hypervisor";
        rev = "v51.0";
        hash = "sha256-RdwQg6/EI+oGkyNXnu5t1q87oTXev25XpIaE+PWDTx4=";
      };
      # Only consulted if something builds the *unpatched* package; the fork
      # replaces cargoDeps outright.
      cargoHash = "sha256-l1EYYJZBUCcnrJdiEjmwzZBqhpZC4h+wSTM6ZWXHDCU=";
    });
  })

  microvmOverlay

  (final: prev: {
    cloud-hypervisor-graphics = prev.cloud-hypervisor-graphics.overrideAttrs (old: {
      # Same expression Spectrum uses, with a hash that matches what the current
      # fetchCargoVendor actually produces for that source and patch set.
      cargoDeps = final.rustPlatform.fetchCargoVendor {
        inherit (old) src patches;
        hash = "sha256-FEdBWrE8ANIM1ilgtBBQUpJpEvItvIXf5m80XQaCV5U=";
      };
    });
  })
]
