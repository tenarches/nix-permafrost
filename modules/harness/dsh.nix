{
  flake.modules.nixos.harness-dsh =
    {
      inputs,
      pkgs,
      lib,
      config,
      ...
    }:

    # The DeepSeek Harness.
    #
    # dsh is a Cordis plugin-DI launcher rather than a conventional CLI, and it
    # reads two files that mean different things:
    #
    #   ~/.dsh/settings.yaml       user settings, hot-reloaded, namespaced per
    #                              plugin. Model providers live here. This is also
    #                              what the web Models page writes.
    #   ~/.dsh/cordis.patch.yml    composition: which plugins are mounted and with
    #                              what config. MCP servers and the default model
    #                              live here.
    #
    # Both are rendered from Nix and then *copied* into the guest, not symlinked.
    # dsh rewrites `~/.dsh/profiles/<name>/cordis.yml` on every boot and the web UI
    # writes settings.yaml in place, so a read-only store symlink anywhere under
    # ~/.dsh breaks it. Copying costs nothing here: the guest home is a fresh
    # volume on every boot, so the Nix-rendered defaults are restored each launch
    # and remain editable for the life of the session.

    let
      models = import ../_lib/models.nix { inherit pkgs lib; };

      # The LAN MCP gateway, declared in harness/mcp.nix.
      inherit (config.permafrost.mcp) gatewayUrl;

      # dsh's own plaintext listener, loopback-only. `tailscale serve` in
      # harness/tailscale.nix is what puts https in front of it, and must name
      # the same port.
      port = 3080;

      # Vendored rather than taken from the llm-agents input, which is still on
      # 0.1.1-rc.2 — see modules/_pkgs/dsh.nix for the version pin and the
      # update procedure.
      dshPkg = pkgs.callPackage ../_pkgs/dsh.nix { };

      # dsh's environment. Named rather than written straight into
      # environment.variables because a systemd user unit does not inherit that
      # — verified in the guest, where a transient user unit saw all three
      # unset — and the user service below has to be given them explicitly.
      # BIFROST_API_KEY in particular is not optional: the adapter resolves the
      # variable named by apiKeyEnv and errors at dispatch when it is missing.
      dshEnv = {
        # The microvm is the isolation boundary, so dsh's own sandbox is off and
        # nothing prompts for approval. bwrap is deliberately absent for the same
        # reason.
        DSH_PERMISSION_MODE = "danger-full-access";

        # Telemetry is off by default, but this also suppresses the anonymous
        # user id that would otherwise be stamped on every provider request —
        # including the ones going to our own endpoint. Any non-empty value is an
        # authoritative opt-out.
        DSH_TELEMETRY_DISABLED = "1";

        # Bifrost is unauthenticated on the LAN, but the adapter still resolves
        # the variable named by apiKeyEnv and errors when it is unset.
        BIFROST_API_KEY = "not-required";
      };

      # Bifrost (fronting vLLM) speaks OpenAI, so it belongs to the pi-ai adapter.
      # llm-deepseek is the native DeepSeek route and cannot be pointed at a
      # gateway this way.
      #
      # The adapter is mounted by the base bundle but dormant: it registers no
      # routes until a `llm-pi-ai:` settings section supplies provider profiles.
      # This section is what wakes it.
      providerId = "bifrost";

      # Every level the models offer. `off` maps to null — the level exists and
      # disables thinking, rather than being a wire value to send. The rest pass
      # through unchanged.
      #
      # xhigh is present deliberately: it is selectable, just never the default.
      # `medium` must be here or the provider default below fails at dispatch with
      # UNSUPPORTED_REASONING_EFFORT.
      reasoningEfforts = {
        off = null;
        minimal = "minimal";
        low = "low";
        medium = "medium";
        high = "high";
        xhigh = "xhigh";
      };

      settingsFile = (pkgs.formats.yaml { }).generate "dsh-settings.yaml" {
        llm-pi-ai.providers.${providerId} = {
          displayName = "Bifrost (petunia)";
          api = "openai-completions";
          baseURL = models.baseUrl;

          # The endpoint wants no key, but the adapter resolves a credential per
          # request and errors when the named variable is unset — so the name has
          # to point at something. The value is set in environment.variables
          # below.
          apiKeyEnv = "BIFROST_API_KEY";

          # THE default reasoning effort: dispatch resolves each request as
          # `options.reasoningEffort ?? profile.reasoning`. The models themselves
          # default to xhigh, which spends most of the context thinking before
          # reaching the task.
          reasoning = models.defaultThinkingLevel;
          thinkingBudgets = models.dshThinkingBudgets;

          # A fallback only: every model in the list carries its own
          # contextWindow and that is what dispatch uses. It matters for a model
          # added without one, so it tracks the larger of the two windows
          # rather than lagging at the 128k it used to name.
          defaultContextWindow = 262144;
          defaultInput = [
            "text"
            "image"
          ];

          # pi-ai infers the request shape from the URL and treats an address it
          # does not recognise as OpenAI itself. These two are the usual corrections
          # for an OpenAI-compatible gateway that is not OpenAI. If a request is
          # rejected outright, `thinkingFormat` is the next lever — the adapter
          # ships `qwen` and `qwen-chat-template` alongside the generic default.
          compat = {
            supportsDeveloperRole = false;
            maxTokensField = "max_tokens";
          };

          # Per model rather than the route's `defaultMaxTokens`: the adapter treats
          # that one as a description of the model's capability and never lets it
          # become a per-request cap, while a model's own `maxTokens` does become
          # the request default. Only the latter stops a reasoning run.
          models = map (model: {
            inherit (model) id name contextWindow;
            inherit (models) maxTokens;
            input = [
              "text"
              "image"
            ];
            inherit reasoningEfforts;
          }) models.models;
        };
      };

      # The one MCP row. dsh mounts no server by default — each one is tool code
      # the model can reach outside the agent's own sandbox — so this is still an
      # explicit act, even though it is now an address rather than a package.
      #
      # streamable-http rather than stdio, which is what every server here used
      # to be. Two things follow from that. The gateway is not a child process,
      # so nothing it logs lands in the session's stderr the way a spawned
      # server's did. And it is reached over the bridge, so a gateway that is
      # down surfaces as a connection error rather than a binary that fails to
      # exec.
      #
      # failOnStartupError is left at its default of false: a gateway that is
      # unreachable should cost the MCP tools, not the whole harness.
      #
      # Tools arrive namespaced by serverName, so they are `mcp__gateway__<tool>`
      # — one namespace for everything the gateway fronts, rather than one per
      # server as when each ran here.
      gatewayRow = {
        id = "mcp-gateway";
        name = "@deepseek-ai/dsh-mcp-client";
        config = {
          serverName = "gateway";
          transport = "streamable-http";
          url = gatewayUrl;
        };
      };

      # The composition layer: a list of patch rows, each either an override keyed
      # by `id` or an `insert` of new rows.
      #
      # Generated rather than hand-written. The format has a `!!js` tag for values
      # evaluated at load time, which a Nix attrset cannot express — but nothing
      # here needs one, and generating keeps the file's indentation out of the
      # formatter's reach.
      #
      # A patch replaces the targeted row's whole `config` rather than merging into
      # it. That is safe for agent-default-model, whose entire config is these two
      # keys, but it is why nothing else here overrides an existing row.
      patchFile = (pkgs.formats.yaml { }).generate "dsh-cordis.patch.yml" [
        {
          id = "agent-default-model";
          config = {
            provider = providerId;
            model = models.defaultModel;
          };
        }
        { insert = [ gatewayRow ]; }
      ];

      # dsh has no TUI; `dsh web` serves a browser SPA. It stays on loopback and
      # `tailscale serve` is what the tailnet talks to.
      #
      # The browser will not run the SPA over plain http from anywhere but
      # loopback: it mints an id for every RPC with `crypto.randomUUID()`, which
      # only exists in a secure context, so the first /api call from
      # `http://<address>` dies with "crypto.randomUUID is not a function".
      # Serving the same UI over https fixes it at the origin, which is the only
      # place it can be fixed — there is no dsh setting for this.
      #
      # --trusted-host names the authority the proxy forwards under. The /api
      # browser-trust fence accepts loopback unconditionally and otherwise wants
      # a match here. The name is the node's own tailnet name, which only exists
      # once the node has joined, so it is read at start rather than baked in.
      # Rewriting the Host header at the proxy would do the same job, at the
      # cost of lying to the application about which address the browser asked
      # for.
      dsh-web = pkgs.writeShellApplication {
        name = "dsh-web";

        # Pins the exact dsh this module was built against rather than taking
        # whatever `dsh` the ambient PATH resolves to. The unit below now runs
        # through a login shell, so a bare name would resolve — this is about
        # which build answers, not whether one does.
        runtimeInputs = [
          dshPkg
          config.services.tailscale.package
          pkgs.jq
        ];

        text = ''
          # Empty when the node is not on the tailnet (no key was delivered, or
          # tailscaled is down), in which case only loopback is trusted.
          trusted=()
          host=$(tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // empty' || true)
          host=''${host%.}
          if [ -n "$host" ]; then
            trusted=(--trusted-host "$host")
          fi

          # --no-open because there is no browser in the guest. Reachable two
          # ways once this is running:
          #
          #   https://<node>.<tailnet>.ts.net
          #     from anywhere on the tailnet the ACL allows, through
          #     `tailscale serve`
          #   http://localhost:${toString port}
          #     through ssh -L ${toString port}:127.0.0.1:${toString port} permafrost
          exec dsh web --no-open --port ${toString port} "''${trusted[@]}" "$@"
        '';
      };

      # Cycling models. The default lives in the composition layer rather than
      # settings, so this is a patch-file edit and needs the profile restarted;
      # settings.yaml is the hot-reloaded half.
      dsh-model = pkgs.writeShellApplication {
        name = "dsh-model";
        runtimeInputs = [ pkgs.yq-go ];
        text = ''
          PATCH="''${DSH_HOME:-$HOME/.dsh}/cordis.patch.yml"

          if [ $# -ne 1 ]; then
            echo "usage: dsh-model <model-id>" >&2
            echo >&2
            echo "Available:" >&2
            ${lib.concatMapStringsSep "\n" (m: ''echo "  ${m.id}" >&2'') models.models}
            echo >&2
            echo "Current: $(yq -r '.[] | select(.id == "agent-default-model") | .config.model' "$PATCH")" >&2
            exit 2
          fi

          yq -i '(.[] | select(.id == "agent-default-model") | .config.model) = "'"$1"'"' "$PATCH"
          echo "Default model is now $1. Restart the profile for it to take effect."
        '';
      };
    in

    {
      environment.systemPackages = [
        dshPkg
        # `dsh plugin ... add <pkg>` forwards to pnpm, which has to be on PATH
        # for optional bundles (the subagent-codex and subagent-claude-code
        # providers, a third-party TUI) to be installable at all.
        pkgs.pnpm
        # dsh-model edits the patch file in place.
        pkgs.yq-go
      ];

      # This harness's *configuration* is generated above and copied into the
      # ephemeral home on every boot, so none of it is shared. Its *data* is a
      # different matter: the sessions directory is the conversation history, and
      # sealing it into the guest means a long-horizon task cannot be resumed
      # after a shutdown.
      #
      # Three narrow shares rather than one on ~/.dsh, because the rest of that
      # directory has to stay ephemeral. Observed in a used guest:
      #
      #   settings.yaml, cordis.patch.yml  installed from the store by the
      #                                    activation script below, so a share
      #                                    would have the guest rewrite the
      #                                    host's copies on every boot
      #   skills/                          the same, except the script `rm -rf`s
      #                                    it first — on a share that deletes a
      #                                    host directory
      #   profiles/                        1.8M of symlinks into the guest's own
      #                                    /nix/store, meaningless on the host
      #                                    and dangling the moment a path is
      #                                    garbage-collected
      permafrost.shares = [
        {
          # Conversation history, zstd-compressed JSONL, one directory per
          # workspace path. 14M after a day's use — the large one of the three.
          host = ".dsh/sessions";
          guest = ".dsh/sessions";
        }
        {
          # Content-addressed blobs the sessions reference. Has to travel with
          # them, or restored history comes back with holes in it.
          host = ".dsh/attachments";
          guest = ".dsh/attachments";
        }
        {
          # Web UI state: the workspace list and the session/project cache.
          host = ".dsh/storages";
          guest = ".dsh/storages";
        }
      ];

      environment.variables = dshEnv;

      # Deliberately no wantedBy: the unit exists to be started by hand and
      # nothing pulls it in, so a guest boots without a web UI listening. Note
      # that `systemctl --user enable` on it would not do what the name
      # suggests — enabling is linking into a target, which is precisely the
      # autostart being avoided. `systemctl --user start dsh-web` is the whole
      # interface, with `journalctl --user -u dsh-web` for its output.
      #
      # The dsh-web command stays on PATH as well, for a one-off run with the
      # output in front of you. Only one of the two can hold port 3080 at a
      # time; the loser exits with an address-in-use error, which is clear
      # enough not to need guarding against.
      systemd = {
        # The share symlinks land *inside* ~/.dsh, which nothing else creates this
        # early. Left to itself systemd-tmpfiles would make that parent as part of
        # the symlink line — root:root 0755 — and the activation script below,
        # which runs as the agent, could then not write settings.yaml into it.
        # Rules are applied in path order, so this holds whichever line comes first.
        tmpfiles.rules = [ "d /home/agent/.dsh 0700 agent users - -" ];

        user.services.dsh-web = {
          description = "dsh web UI";
          serviceConfig = {
            Type = "exec";

            # Started through a login shell, which is the whole point of the
            # line rather than an affectation.
            #
            # An agent harness spawns things: `bash` for every shell tool, git,
            # node, whatever the task calls for. NixOS renders an explicit
            # Environment="PATH=..." onto a user unit — coreutils, findutils,
            # grep, sed, systemd and nothing else — and that overrides the user
            # manager's own environment. dsh's bash tool therefore failed with
            #
            #   Error: spawn bash ENOENT
            #
            # which takes the whole toolchain with it: no tests, no commits, no
            # background jobs. There is not even a `sh` on that PATH.
            #
            # `bash -l` sources /etc/profile, which *replaces* PATH rather than
            # appending to it, and brings the rest of the session environment
            # with it — LOCALE_ARCHIVE, TZDIR, NIX_PATH. That makes the service
            # equivalent to what `ssh permafrost && dsh-web` always gave, which
            # is what this unit displaced. Verified against a unit pinned to the
            # real minimal PATH: without -l, `git` is not found; with it, PATH
            # is the full login PATH and bash, git and node all resolve.
            #
            # `exec` so bash replaces itself: MainPID stays the server, and
            # Type=exec and `systemctl stop` keep their usual meaning.
            #
            # Absolute path to bash because, at the moment this line runs, the
            # minimal PATH is still in force and there is no shell on it.
            ExecStart = "${lib.getExe pkgs.bashInteractive} -l -c 'exec ${lib.getExe dsh-web}'";

            # dsh's own three. A login shell does not touch these, and the
            # PATH systemd renders alongside them is superseded above.
            Environment = lib.mapAttrsToList (k: v: "${k}=${v}") dshEnv;
            WorkingDirectory = "%h";

            # Started by hand, so a crash should stay crashed and be visible in
            # the journal rather than being papered over by a restart loop.
            Restart = "no";
          };
        };
      };

      # Taken as a function so `lib` here is home-manager's, which carries the
      # activation-script DAG helpers the NixOS lib does not.
      home-manager.users.agent =
        { lib, ... }:
        {
          home.packages = [
            dsh-web
            dsh-model
          ];

          # home.file would symlink these read-only into the store, which dsh
          # cannot work with — see the header. An activation script copies instead.
          home.activation.dshDefaults = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
            run ${pkgs.coreutils}/bin/install -Dm0644 \
              ${settingsFile} "$HOME/.dsh/settings.yaml"
            run ${pkgs.coreutils}/bin/install -Dm0644 \
              ${patchFile} "$HOME/.dsh/cordis.patch.yml"

            # Rank-400 discovery root. Deliberately not ~/.agents/skills, which
            # ranks below it but is a host share — writing there would put guest
            # state on the host. The host's own skills are still read from there.
            run ${pkgs.coreutils}/bin/rm -rf "$HOME/.dsh/skills"
            run ${pkgs.coreutils}/bin/mkdir -p "$HOME/.dsh/skills"
            run ${pkgs.coreutils}/bin/cp -rL --no-preserve=mode,ownership \
              ${inputs.agent-skills}/. "$HOME/.dsh/skills/"
            run ${pkgs.coreutils}/bin/chmod -R u+w "$HOME/.dsh/skills"
          '';
        };
    };
}
