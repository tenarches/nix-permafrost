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

      # The address the TLS front end serves and the helper prints. Read from
      # the guest's own identity rather than injected, so the two cannot
      # disagree.
      inherit (config.permafrost.identity) ip fqdn;

      # Every authority the /api Host-header fence has to accept. Port-less
      # entries match on any port, so this does not have to track tlsPort.
      trustedHosts = [ ip ] ++ lib.optional (fqdn != null) fqdn;

      # dsh's own plaintext listener, loopback-only, and the TLS port caddy
      # publishes on the bridge.
      port = 3080;
      tlsPort = 3443;

      # Under caddy's StateDirectory, so systemd creates and owns it and the
      # unit's own ReadWritePaths already cover it.
      tlsDir = "/var/lib/caddy/tls";

      dshPkg = inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.dsh;

      # dsh's environment. Named rather than written straight into
      # environment.variables because a systemd user unit does not inherit that
      # — verified in the guest, where a transient user unit saw all three
      # unset — and the user service below has to be given them explicitly.
      # VLLM_API_KEY in particular is not optional: the adapter resolves the
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

        # The endpoint wants no key, but the adapter still resolves the variable
        # named by apiKeyEnv and errors when it is unset.
        VLLM_API_KEY = "not-required";
      };

      # Where the launcher's virtiofs share lands. Root-only, so the agent
      # cannot read the key out of it — which matters only because the agent
      # no longer has a route to root; see guest/base.nix.
      vaultTlsDir = "/run/vault-tls";

      # A self-signed leaf for the guest's address. No authority, no chain,
      # nothing to install anywhere — the browser is asked about this exact
      # certificate and that is the end of it.
      #
      # Idempotent: a `systemctl restart caddy` mid-session must not mint a new
      # one, or the certificate the browser was just shown stops matching.
      tlsCert = pkgs.writeShellApplication {
        name = "dsh-web-tls-cert";
        runtimeInputs = [ pkgs.openssl ];
        text = ''
          if [ -s ${tlsDir}/cert.pem ] && [ -s ${tlsDir}/key.pem ]; then
            exit 0
          fi

          mkdir -p ${tlsDir}
          openssl req -x509 -newkey rsa:2048 -noenc -days 365 \
            -subj "/CN=${ip}" \
            -addext "subjectAltName=IP:${ip}" \
            -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
            -addext "extendedKeyUsage=serverAuth" \
            -keyout ${tlsDir}/key.pem \
            -out ${tlsDir}/cert.pem
          chmod 0600 ${tlsDir}/key.pem
          chmod 0644 ${tlsDir}/cert.pem
        '';
      };

      # vLLM speaks OpenAI, so it belongs to the pi-ai adapter. llm-deepseek is the
      # native DeepSeek route and cannot be pointed at a gateway this way.
      #
      # The adapter is mounted by the base bundle but dormant: it registers no
      # routes until a `llm-pi-ai:` settings section supplies provider profiles.
      # This section is what wakes it.
      providerId = "vllm-local";

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
          displayName = "vLLM (petunia)";
          api = "openai-completions";
          baseURL = models.baseUrl;

          # The endpoint wants no key, but the adapter resolves a credential per
          # request and errors when the named variable is unset — so the name has
          # to point at something. The value is set in environment.variables
          # below.
          apiKeyEnv = "VLLM_API_KEY";

          # THE default reasoning effort: dispatch resolves each request as
          # `options.reasoningEffort ?? profile.reasoning`. The models themselves
          # default to xhigh, which spends most of a 128k context thinking before
          # reaching the task.
          reasoning = models.defaultThinkingLevel;
          thinkingBudgets = models.dshThinkingBudgets;

          defaultContextWindow = 131072;
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

          models = map (model: {
            inherit (model) id name contextWindow;
            input = [
              "text"
              "image"
            ];
            inherit reasoningEfforts;
          }) models.models;
        };
      };

      # One plugin row per MCP server. There is no `mcpServers` dict in dsh, and no
      # server is mounted by default — each one is executable code running outside
      # the agent sandbox, so mounting it is an explicit act.
      #
      # Commands are store paths rather than bare names: PATH inside a plugin's
      # spawn environment is not this module's to guarantee.
      #
      # Invocation forms were each checked against the built binary: context7, time
      # and nixos speak MCP bare over stdin; terraform needs a `stdio` subcommand.
      #
      # github-mcp-server is installed but deliberately absent here — it exits at
      # startup unless GITHUB_PERSONAL_ACCESS_TOKEN is set, and no token reaches
      # this guest. docs/dsh.md has the row to paste once one does.
      mcpRow = row: {
        id = "mcp-${row.name}";
        name = "@deepseek-ai/dsh-mcp-client";
        config = {
          serverName = row.name;
          transport = "stdio";
          command = lib.getExe row.package;
        }
        // lib.optionalAttrs (row ? args) { inherit (row) args; };
      };

      mcpServers = [
        {
          name = "context7";
          package = pkgs.context7-mcp;
        }
        {
          name = "time";
          package = pkgs.mcp-server-time;
        }
        {
          name = "nixos";
          package = pkgs.mcp-nixos;
        }
        # --log-level fatal is about the terminal, not the server. Logrus writes to
        # stderr, which a stdio MCP child inherits from whatever launched dsh, so
        # every session opened with the web helpers printed four lines ending in
        #
        #   NewSessionHandler failed to create TFE client
        #     error="open ~/.terraform.d/credentials.tfrc.json: no such file"
        #   Session has no valid TFE client - TFE tools will not be available
        #
        # which reads as a failed start and is not one. The session handler tries
        # for an HCP Terraform client unconditionally — --toolsets changes nothing,
        # confirmed by diffing tools/list between `all` and `registry`: nine
        # registry tools either way, no TFE tool ever registered without a token.
        # No token reaches this guest, so the client it is failing to build is one
        # nothing here would use.
        #
        # fatal rather than error, because the second line is a warning and the
        # first is logged at error. Nothing is lost that would still be
        # recoverable: a log level cannot silence a fatal, and JSON-RPC is on
        # stdout, untouched. One line survives — "Terraform MCP Server running on
        # stdio", printed to stderr directly rather than through logrus.
        {
          name = "terraform";
          package = pkgs.terraform-mcp-server;
          args = [
            "stdio"
            "--log-level"
            "fatal"
          ];
        }
      ];

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
        { insert = map mcpRow mcpServers; }
      ];

      # dsh has no TUI; `dsh web` serves a browser SPA. It stays on loopback and
      # caddy below is what the host talks to — see the header comment on
      # services.caddy for why the plaintext bind cannot be exposed directly.
      #
      # --trusted-host names the authority caddy will forward under. The /api
      # browser-trust fence accepts loopback unconditionally and otherwise wants
      # a match here; a port-less entry matches that host on any port, so this
      # does not have to track tlsPort. Rewriting the Host header at the proxy
      # would do the same job, at the cost of lying to the application about
      # which address the browser asked for.
      dsh-web = pkgs.writeShellApplication {
        name = "dsh-web";

        # Pins the exact dsh this module was built against rather than taking
        # whatever `dsh` the ambient PATH resolves to. The unit below now runs
        # through a login shell, so a bare name would resolve — this is about
        # which build answers, not whether one does.
        runtimeInputs = [ dshPkg ];

        text = ''
          # --no-open because there is no browser in the guest. Reachable two
          # ways once this is running:
          #
          #   https://${ip}:${toString tlsPort}
          #     from the host, through caddy
          #   http://localhost:${toString port}
          #     through ssh -L ${toString port}:127.0.0.1:${toString port} permafrost
          exec dsh web --no-open --port ${toString port} ${
            lib.concatMapStringsSep " " (h: "--trusted-host ${h}") trustedHosts
          } "$@"
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

      # Only the TLS front end is published. dsh's own listener stays on
      # loopback, reachable through an ssh tunnel and nothing else.
      networking.firewall.allowedTCPPorts = [ tlsPort ];

      # TLS in front of the web UI, because the browser will not run it
      # otherwise.
      #
      # The SPA mints an id for every RPC with `crypto.randomUUID()`, and the
      # browser only defines that in a *secure context*. `http://${ip}:${toString port}`
      # is not one — no browser treats a plain-http RFC1918 origin as
      # trustworthy — so the first /api call dies with "crypto.randomUUID is not
      # a function" and the provider directory, Agent preset and Models panes
      # never load. Serving the same UI over https fixes it at the origin, which
      # is the only place it can be fixed: there is no dsh setting for this.
      #
      # This replaces the earlier all-interfaces plaintext bind, and is a
      # narrowing rather than a widening — the UI drives an agent with its
      # sandbox off, and it is no longer on the bridge in the clear.
      #
      # The certificate is handed to caddy already made, rather than left to
      # `tls internal`. That directive engages caddy's PKI app, which stands up
      # a local certificate authority and then tries to add its root to the
      # system trust store — by shelling out to `sudo`, from a service running
      # as an unprivileged user. `skip_install_trust` declines the attempt but
      # leaves the mechanism in place, and a web server that can reach for
      # privilege to do PKI is the wrong shape for a guest like this one.
      #
      # With an explicit certificate none of it is reached: caddy reports
      # "skipping automatic certificate management because one or more matching
      # certificates are already loaded", creates no authority, and touches no
      # trust store. Verified against caddy 2.11.4.
      #
      # The guest is rebuilt from scratch on every boot and /var/lib with it, so
      # the certificate is new each launch and the browser asks to accept it
      # once per launch. Accepting still yields an https origin, which is the
      # whole point. The alternatives are both worse: keeping it across boots
      # needs a host share, and baking it into the store publishes the private
      # key to anyone who can read /nix/store.
      services.caddy = {
        enable = true;

        # There is no plaintext vhost, so the automatic http->https redirect
        # site would bind :80 for nothing.
        globalConfig = "auto_https disable_redirects";

        virtualHosts."https://${ip}:${toString tlsPort}" = {
          # The certificate carries the name as a DNS SAN, so serving it costs
          # nothing extra. Without this a request arriving under the name
          # matches no site and caddy answers it itself with an empty 200 —
          # which looks like success and renders a blank page.
          serverAliases = lib.optional (fqdn != null) "https://${fqdn}:${toString tlsPort}";

          # Bind the wildcard rather than the address itself. caddy.service
          # does require network-online.target, so ${ip} would normally be
          # assigned by then — but that makes the listener's success depend on
          # systemd-networkd-wait-online agreeing, and this address is
          # statically configured on an interface matched by a glob. The
          # wildcard removes the question. Nothing is widened by it: the site
          # address below still decides which Host is served, caddy matches an
          # IP site by the connection's local address, and only ${toString tlsPort}
          # is open in the firewall.
          listenAddresses = [ "0.0.0.0" ];

          # Nothing public can vouch for an RFC1918 address, so the certificate
          # is the self-signed one minted below. 502s until `dsh-web` is
          # running; that is expected, not a fault.
          extraConfig = ''
            tls ${tlsDir}/cert.pem ${tlsDir}/key.pem
            reverse_proxy 127.0.0.1:${toString port}
          '';
        };
      };

      # Minting it is the service's own first act, as its own unprivileged
      # user, inside the StateDirectory systemd already gives it. Nothing here
      # runs as root, and nothing asks to.
      #
      # preStart rather than serviceConfig.ExecStartPre: it is types.lines, so
      # it merges instead of colliding if the caddy module ever grows one of
      # its own.
      # A Vault-issued certificate, when the launcher managed to get one, takes
      # precedence over the self-signed fallback below.
      #
      # This is the only root-run step in the whole path, and it is
      # provisioning rather than escalation: systemd starts it as root to
      # install a file with ownership caddy cannot give itself, and it holds no
      # Vault access, no key generation, and no trust-store contact. caddy's
      # own units keep their "nothing runs as root, and nothing asks to"
      # property.
      #
      # ConditionPathExists rather than a shell test, so a launch with no
      # certificate skips the unit entirely instead of running a no-op — the
      # skip is then visible in `systemctl status` rather than silent.
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

        services = {
          dsh-web-tls-vault = {
            description = "Install the Vault-issued dsh web UI certificate";
            before = [ "caddy.service" ];
            requiredBy = [ "caddy.service" ];
            unitConfig = {
              # Without this the condition below is evaluated before the
              # virtiofs share is mounted, the unit skips, and a certificate
              # that was delivered is silently replaced by a self-signed one.
              RequiresMountsFor = vaultTlsDir;
              ConditionPathExists = "${vaultTlsDir}/cert.pem";
            };
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
            };
            script = ''
              install -d -m 0750 -o caddy -g caddy ${tlsDir}
              install -m 0444 -o caddy -g caddy ${vaultTlsDir}/cert.pem ${tlsDir}/cert.pem
              install -m 0400 -o caddy -g caddy ${vaultTlsDir}/key.pem ${tlsDir}/key.pem
            '';
          };

          caddy = {
            # Unchanged, and load-bearing precisely because it is idempotent:
            # when the unit above has run, both files already exist and this
            # exits 0 without generating anything. When it has not, the
            # self-signed path fires exactly as it did before Vault existed.
            preStart = "${lib.getExe tlsCert}";

            serviceConfig = {
              # Both come from the unit caddy ships and neither is wanted:
              # ${toString tlsPort} is above 1024, and a reverse proxy has no
              # business holding CAP_NET_ADMIN. An empty assignment in the
              # drop-in resets the list the packaged unit set.
              AmbientCapabilities = [ "" ];
              CapabilityBoundingSet = [ "" ];
            };
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
