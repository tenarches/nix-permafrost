# herdr's agent integrations, extracted from the pinned binary.
#
# `herdr integration install <agent>` writes a hook, plugin or extension into
# that agent's config directory. The payloads are versioned inside the herdr
# binary, so they are generated from the package rather than copied by hand — a
# herdr version bump carries new payloads with it.
#
# Install writes into $HOME, so each target config directory has to pre-exist.
# It needs no network and reads nothing outside the directories created here.
{ pkgs, lib }:

pkgs.runCommand "herdr-integrations-${pkgs.herdr.version}"
  {
    nativeBuildInputs = [ pkgs.makeWrapper ];
    meta = {
      description = "Agent hooks and plugins bundled with herdr ${pkgs.herdr.version}";
      inherit (pkgs.herdr.meta) homepage license;
    };
  }
  ''
    export HOME="$(mktemp -d)"
    mkdir -p "$HOME"/.claude "$HOME"/.pi/agent "$HOME"/.config/opencode

    herdr=${lib.getExe pkgs.herdr}
    "$herdr" integration install claude
    "$herdr" integration install pi
    "$herdr" integration install opencode

    # `herdr integration status` parses HERDR_INTEGRATION_VERSION out of the
    # script itself, so the raw file is kept alongside the wrapper.
    install -Dm555 "$HOME/.claude/hooks/herdr-agent-state.sh" \
      "$out/libexec/herdr-agent-state.sh"

    # The hook fails soft — it exits 0 rather than break a Claude session — so
    # a missing python3 or mktemp would silently disable the integration
    # instead of reporting anything. Pin both onto its PATH.
    makeWrapper ${lib.getExe pkgs.bash} "$out/bin/herdr-agent-state" \
      --add-flags "$out/libexec/herdr-agent-state.sh" \
      --prefix PATH : ${
        lib.makeBinPath [
          pkgs.python3
          pkgs.coreutils
        ]
      }

    # The pi extension and opencode plugin run inside their host agent's own
    # runtime and contain no absolute paths, so they need no wrapping.
    install -Dm444 "$HOME/.pi/agent/extensions/herdr-agent-state.ts" \
      "$out/share/pi/herdr-agent-state.ts"
    install -Dm444 "$HOME/.config/opencode/plugins/herdr-agent-state.js" \
      "$out/share/opencode/herdr-agent-state.js"
  ''
