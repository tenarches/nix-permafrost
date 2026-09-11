{ pkgs, lib }:

# dsh — the DeepSeek Harness.
#
# Vendored rather than taken from the llm-agents input. That input is still on
# 0.1.1-rc.2 and its open bump targets 0.1.5-rc.1, so the only way to run
# 0.1.5-rc.2 is to build it here.
#
# The published 0.1.5 tarballs carry a devDependency,
# @deepseek-ai/dsh-experimental-code-runtime-python, that was never published to
# the registry. npm resolves devDependencies into the lock file even under
# --omit=dev, so the 404 blocks lock generation and `npm ci` alike. It is
# stripped below. Nothing under lib/ references the package — the shipped CLI
# neither imports it nor names it in any bundled config — so removing the
# declaration drops a dangling reference, not a code path.
#
# Manual Update Instructions:
# 1. Update the 'version' string.
# 2. Get the source hash:
#    nix-prefetch-url https://registry.npmjs.org/@deepseek-ai/dsh/-/dsh-${version}.tgz
#    nix hash convert --hash-algo sha256 --to sri <HASH_FROM_ABOVE>
# 3. Regenerate dsh-lock.json (requires npm):
#      tar -xf <TGZ_FILE> && cd package
#      jq 'del(.devDependencies["@deepseek-ai/dsh-experimental-code-runtime-python"])' \
#        package.json > pj && mv pj package.json   # only while the 404 persists
#      npm install --package-lock-only --ignore-scripts
#      cp package-lock.json modules/_pkgs/dsh-lock.json
# 4. Get the npmDepsHash: set it to lib.fakeHash, run `nix build .#permafrost`,
#    and copy the 'got:' hash from the failure message.
pkgs.buildNpmPackage rec {
  pname = "dsh";
  version = "0.1.5-rc.2";

  src = pkgs.fetchurl {
    url = "https://registry.npmjs.org/@deepseek-ai/dsh/-/dsh-${version}.tgz";
    hash = "sha256-9MVIOdaegr8cOlpBqRDDzhQFzZ6dl9dTwMBPQGx9dIA=";
  };

  # The lock file is generated against the patched manifest, so the patch has to
  # be applied here too or `npm ci` rejects the pair as out of sync.
  postPatch = ''
    ${lib.getExe pkgs.jq} \
      'del(.devDependencies["@deepseek-ai/dsh-experimental-code-runtime-python"])' \
      package.json > package.json.patched
    mv package.json.patched package.json
    cp ${./dsh-lock.json} package-lock.json
  '';

  npmDepsFetcherVersion = 2;
  npmDepsHash = "sha256-wqT0GTaUvDoMcOU1l2rKU9XYgaFFT8qSN2bkeTZdmMc=";

  # The tarball ships a prebuilt lib/; there is nothing to compile.
  dontNpmBuild = true;

  nativeBuildInputs = [ pkgs.makeWrapper ];

  # /bin/bash does not exist on NixOS, and dsh's terminal backend hardcodes it.
  postInstall = ''
    substituteInPlace \
      $out/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/dsh-terminal-bash/lib/index.js \
      --replace-fail '"/bin/bash"' '"${lib.getExe pkgs.bashInteractive}"'

    rm $out/bin/dsh
    makeWrapper ${lib.getExe pkgs.nodejs} $out/bin/dsh \
      --argv0 dsh \
      --add-flags "--expose-internals" \
      --add-flags "$out/lib/node_modules/@deepseek-ai/dsh/lib/bin.js"
  '';

  # dsh writes under $HOME on startup, so the version check needs a writable one.
  # versionCheckHomeHook would supply it but is not in this nixpkgs pin.
  doInstallCheck = true;
  nativeInstallCheckInputs = [ pkgs.versionCheckHook ];
  versionCheckProgramArg = "--version";
  preInstallCheck = ''
    export HOME=$(mktemp -d)
  '';

  meta = {
    description = "Open-source agent harness developed by DeepSeek AI";
    homepage = "https://github.com/deepseek-ai/deepseek-harness";
    changelog = "https://github.com/deepseek-ai/deepseek-harness/releases";
    license = lib.licenses.mit;
    sourceProvenance = with lib.sourceTypes; [
      binaryBytecode
      fromSource
    ];
    mainProgram = "dsh";
    platforms = lib.platforms.all;
  };
}
