# Host-side vhost-user GPU device for microvm.graphics.
#
# crosvm is pinned to an *older source revision* than the host's nixpkgs ships,
# but is built with the host's own toolchain and libraries.
#
# Why the pin: crosvm must speak the same vhost-user dialect as the
# Spectrum-patched cloud-hypervisor that microvm.nix pairs it with, and those
# two have diverged. The fork (see overlays/cloud-hypervisor-graphics.nix) asks
# for GET_SHARED_MEMORY_REGIONS (message 1004, protocol bit 0x8000_0000), which
# crosvm has since replaced with the standardized SHMEM_MAP. Current crosvm has
# no handler for 1004 and drops the connection, so the VM dies with
# VhostUserGetSharedMemoryRegions(Disconnected). The newest crosvm that still
# implements the old message and bit is 470e07c (2025-11-19, what nixos-25.11
# shipped) — verified in third_party/vmm_vhost/src/message.rs. nixos-26.05 and
# later are already on SHMEM_MAP.
#
# Why not a second, older nixpkgs: an earlier revision of this repo took the
# whole crosvm from an EOL nixpkgs input (nixos-25.05), which linked glibc 2.40
# next to a host Mesa built against 2.42 (GLIBC_ABI_GNU2_TLS). crosvm's Mesa
# loader then failed to open the driver, rutabaga fell back from virglrenderer
# to a 2D backend, and the guest ended up with no capsets ("invalid capset id
# 4294967295"), which kills the cross-domain context wayland-proxy-virtwl
# needs. Building the pinned source on the host's nixpkgs links the same glibc
# and Mesa as the host, so the default /run/opengl-driver lookup works and no
# loader wrapper is needed.
#
# Remove once Spectrum's fork moves to SHMEM_MAP.
{ pkgs }:

let
  # Same fetcher and arguments as nixos-25.11's pkgs/by-name/cr/crosvm.
  src = pkgs.fetchgit {
    url = "https://chromium.googlesource.com/chromiumos/platform/crosvm";
    rev = "470e07c23ea9f76fcbc922b03465be2d0d28e2ce";
    hash = "sha256-/1B2ddxrefjoVUCir051vblftZAluCc80yY+StpFHXI=";
    fetchSubmodules = true;
  };
in
pkgs.crosvm.overrideAttrs (_: {
  version = "0-unstable-2025-11-19";
  inherit src;

  # buildRustPackage derives cargoDeps from cargoHash at construction time, so
  # overriding src alone would keep vendoring the *current* revision's
  # dependencies; replace cargoDeps outright. The hash is nixos-25.11's
  # cargoHash for this exact source.
  cargoDeps = pkgs.rustPlatform.fetchCargoVendor {
    inherit src;
    hash = "sha256-NeyJLsE/Uvcg/kNzS1SXEBjExKwbjcHkkhT2jSQjxx4=";
  };
})
