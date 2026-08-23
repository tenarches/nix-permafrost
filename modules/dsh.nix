{
  inputs,
  pkgs,
  lib,
  guestIp,
  ...
}:

# The DeepSeek Harness guest.
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
  models = import ./models.nix { inherit pkgs lib; };

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
      # to point at something. The value is supplied by spec.env.
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
    {
      name = "terraform";
      package = pkgs.terraform-mcp-server;
      args = [ "stdio" ];
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

  # dsh has no TUI. `dsh web` serves a browser SPA and defaults to loopback,
  # which is the right default for a UI driving an agent with the sandbox off.
  dsh-web = pkgs.writeShellApplication {
    name = "dsh-web";
    text = ''
      # --no-open because there is no browser in the guest. Reach it with:
      #   ssh -L 3080:127.0.0.1:3080 permafrost-dsh
      exec dsh web --no-open --port 3080 "$@"
    '';
  };

  # The same UI reachable from the host, without an ssh tunnel.
  #
  # This has to go through a patch overlay rather than `--host`, because the
  # webserver's host is a closed enum of exactly "127.0.0.1" and "0.0.0.0" —
  # `--host ${guestIp}` fails schema validation at boot. The CLI separately
  # refuses `--host 0.0.0.0` outright, on the grounds that it "would expose
  # remote code execution to the network". The composition layer has no such
  # guard, so setting the row directly is the only route.
  #
  # Taking that route deliberately. In the guest, "all interfaces" is loopback
  # plus one address on a host-local bridge that is NAT'd outbound, so the
  # exposure is the host and sibling guests — not the network upstream is
  # warning about. It is still a real widening: the UI drives an agent whose
  # sandbox is off, which is why loopback stays the default.
  #
  # No --trusted-host needed. The Host-header fence derives its trusted LAN
  # addresses from the bind, and only does so for an all-interfaces bind —
  # which is what this is.
  lanPatch = (pkgs.formats.yaml { }).generate "dsh-web-lan.patch.yml" [
    {
      id = "webserver";
      config = {
        host = "0.0.0.0";
        port = 3080;
      };
    }
  ];

  dsh-web-lan = pkgs.writeShellApplication {
    name = "dsh-web-lan";
    text = ''
      # http://${guestIp}:3080 from the host. --patch is a launcher flag, so it
      # has to precede the profile's own arguments; `dsh web` is an alias for
      # `--profile web` and would pass it through to the app instead.
      exec dsh --profile web --patch ${lanPatch} --no-open "$@"
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
  # dsh web binds loopback by default; the LAN helper needs this open. The
  # bridge is host-local, so this is not exposed beyond the host and its guests.
  networking.firewall.allowedTCPPorts = [ 3080 ];

  # Taken as a function so `lib` here is home-manager's, which carries the
  # activation-script DAG helpers the NixOS lib does not.
  home-manager.users.agent =
    { lib, ... }:
    {
      home.packages = [
        dsh-web
        dsh-web-lan
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
}
