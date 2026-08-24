{ pkgs, lib }:

pkgs.buildNpmPackage rec {
  pname = "openclaude";
  version = "0.8.0";

  # Manual Update Instructions:
  # 1. Update the 'version' string.
  # 2. Get the source hash:
  #    nix-prefetch-url https://registry.npmjs.org/@gitlawb/openclaude/-/openclaude-${version}.tgz
  #    nix-hash --to-sri --type sha256 <HASH_FROM_ABOVE>
  # 3. Get the npmDepsHash:
  #    - Set npmDepsHash = lib.fakeHash;
  #    - Update openclaude-lock.json (requires npm):
  #      tar -xf <TGZ_FILE>
  #      cd package && npm install --package-lock-only --legacy-peer-deps
  #      cp package-lock.json modules/_pkgs/openclaude-lock.json
  #    - Run: nix build .#claude (or the openclaude package)
  #    - Copy the 'got:' hash from the failure message.
  src = pkgs.fetchurl {
    url = "https://registry.npmjs.org/@gitlawb/openclaude/-/openclaude-${version}.tgz";
    hash = "sha256-N87awOQOI5tXqvH0YwCSmJFKlNajNpxiSVAA9RrcQ3Y=";
  };

  # Use the generated lock file
  postPatch = ''
    cp ${./openclaude-lock.json} package-lock.json
  '';

  npmDepsHash = "sha256-mgIMTe0it5Fyb/FmPBk4epq7ld9JCWKbY0w9Cr71z00=";

  npmFlags = [
    "--legacy-peer-deps"
    "--ignore-scripts"
  ];

  nativeBuildInputs = with pkgs; [
    makeWrapper
  ];

  # Force skipping the build phase entirely by overriding the standard phase
  buildPhase = "true";

  # We will handle installation manually in a custom installPhase
  installPhase = ''
    runHook preInstall

    # Ensure the target directory exists
    mkdir -p $out/lib/node_modules/@gitlawb/openclaude

    # Copy the package files
    cp -r . $out/lib/node_modules/@gitlawb/openclaude

    # Wrap the actual entry point
    makeWrapper $out/lib/node_modules/@gitlawb/openclaude/bin/openclaude $out/bin/openclaude \
      --prefix PATH : ${
        lib.makeBinPath [
          pkgs.nodejs_24
          pkgs.ripgrep
        ]
      }

    runHook postInstall
  '';

  meta = with lib; {
    description = "Open-source coding-agent CLI (Claude Code alternative)";
    homepage = "https://github.com/Gitlawb/openclaude";
    license = licenses.mit;
    platforms = platforms.all;
    mainProgram = "openclaude";
  };
}
