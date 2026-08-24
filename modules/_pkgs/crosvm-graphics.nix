# Host-side vhost-user GPU device for microvm.graphics.
#
# Takes the *pinned* package set (nixpkgs-crosvm, see flake.nix), not the host's.
#
# Two constraints pull in opposite directions. The vhost-user dialect must
# match the Spectrum-patched cloud-hypervisor, which only the pinned
# nixpkgs-crosvm still speaks. But that crosvm is linked against glibc 2.40,
# while the host's Mesa is built against 2.42 and needs GLIBC_ABI_GNU2_TLS — so
# when crosvm's Mesa loader follows the NixOS-baked /run/opengl-driver path it
# fails to open the driver, rutabaga falls back from virglrenderer to a 2D
# backend, and the guest ends up with no capsets at all ("invalid capset id
# 4294967295"). That kills the cross-domain context wayland-proxy-virtwl needs.
#
# So point the loader at the Mesa from crosvm's own generation, which is ABI
# compatible with it. Nothing else on the host is affected: the environment is
# set on this binary only, not on the unit.
{ cpkgs }:

cpkgs.symlinkJoin {
  name = "crosvm-graphics";
  paths = [ cpkgs.crosvm ];
  nativeBuildInputs = [ cpkgs.makeWrapper ];
  # Every one of these has a NixOS-baked /run/opengl-driver default that
  # would pull in the host's Mesa: GBM_BACKENDS_PATH for the gbm backend
  # (the one that actually failed, since dri_gbm.so pulls its own
  # libgallium), __EGL_VENDOR_LIBRARY_FILENAMES for glvnd's EGL vendor
  # discovery, and VK_DRIVER_FILES for the Vulkan ICDs — `vulkan: true` is
  # in the params microvm.nix passes.
  postBuild = ''
    # All of this generation's ICDs, so the host's actual GPU driver is
    # still chosen rather than forcing software Vulkan.
    vkIcds=$(echo ${cpkgs.mesa}/share/vulkan/icd.d/*.json | tr ' ' ':')
    wrapProgram $out/bin/crosvm \
      --set GBM_BACKENDS_PATH ${cpkgs.mesa}/lib/gbm \
      --set LIBGL_DRIVERS_PATH ${cpkgs.mesa}/lib/dri \
      --set __EGL_VENDOR_LIBRARY_FILENAMES ${cpkgs.mesa}/share/glvnd/egl_vendor.d/50_mesa.json \
      --set VK_DRIVER_FILES "$vkIcds" \
      --prefix LD_LIBRARY_PATH : ${
        cpkgs.lib.makeLibraryPath [
          cpkgs.mesa
          cpkgs.libgbm
        ]
      }
  '';
}
