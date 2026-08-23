{ inputs, pkgs, ... }:

let
  inherit (pkgs) lib;

  models = import ./models.nix { inherit pkgs lib; };

  openclaude = pkgs.callPackage ./programs/openclaude.nix { };
  mcpServers = [
    pkgs.context7-mcp
    pkgs.mcp-server-time
    pkgs.github-mcp-server
    pkgs.terraform-mcp-server
    pkgs.mcp-nixos
  ];

  # Every agent can display GUI apps on the host, but through waypipe rather
  # than `gui`: `waypipe ssh agent@<ip> bash -l` needs nothing from this flag.
  #
  # `gui = true` additionally enables microvm.graphics — the in-guest
  # wayland-proxy plus a host-side crosvm virtio-gpu device — which buys you
  # "ssh in first, then launch anything" and Xwayland for X11 clients. It is
  # off by default because that path is upstream-fragile: it needs a
  # Spectrum-patched cloud-hypervisor pinned to 51.0, a crosvm pinned to an
  # older vhost-user dialect, and a Mesa kept on crosvm's own glibc generation
  # (see flake.nix and runners.nix). Turning it on also means building
  # cloud-hypervisor from source and having a live compositor in the launching
  # session — see the preflight check in runners.nix.
  specs = lib.mapAttrs (_: spec: { gui = false; } // spec) rawSpecs;

  rawSpecs = {
    claude = {
      name = "claude";
      tapId = "claude";
      ip = "192.168.33.10";
      mac = "02:00:00:00:00:10";
      vsockCid = 10;
      persistentShares = [
        {
          host = ".claude";
          guest = ".claude";
        }
        {
          host = ".config/claude";
          guest = ".claude-config";
          guestLink = ".claude.json";
        }
      ];
      extraPackages = [
        inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.claude-code
        openclaude
      ]
      ++ mcpServers;
      credentials = {
        ANTHROPIC_API_KEY = "/run/secrets/anthropic-api-key";
      };
    };

    opencode = {
      name = "opencode";
      tapId = "ocode";
      ip = "192.168.33.13";
      mac = "02:00:00:00:00:13";
      vsockCid = 13;
      persistentShares = [
        {
          host = ".config/opencode";
          guest = ".config/opencode";
        }
      ];
      extraPackages = [
        inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.opencode
      ]
      ++ mcpServers;
      credentials = {
        OPENAI_API_KEY = "/run/secrets/openai-api-key";
      };
    };

    pi = {
      name = "pi";
      tapId = "pi";
      ip = "192.168.33.14";
      mac = "02:00:00:00:00:14";
      vsockCid = 14;
      persistentShares = [
        {
          host = ".pi";
          guest = ".pi";
        }
      ];
      extraPackages = [
        inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.pi
        inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.mcporter
      ]
      ++ mcpServers;
      homeFiles = {
        ".pi/agent/models.json".source = models.piModelsJson;
      };
    };

    bv = {
      name = "bv";
      tapId = "bv";
      ip = "192.168.33.16";
      mac = "02:00:00:00:00:16";
      vsockCid = 16;
      persistentShares = [
        # Pi auth — Gemini OAuth tokens (written by `pi /login`)
        {
          host = ".pi";
          guest = ".pi";
        }
        # Builder-verifier project tree: persistent state (sessions, node_modules)
        {
          host = "bv";
          guest = "bv";
        }
        # mcporter MCP server configuration
        {
          host = ".mcporter";
          guest = ".mcporter";
        }
      ];
      overlays = [
        (_final: prev: {
          nodejs = prev.nodejs_24;
        })
      ];
      extraPackages = [
        inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.pi
        inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.mcporter
        pkgs.nodejs
      ]
      ++ mcpServers;
      credentials = {
        GITHUB_TOKEN = "/run/secrets/github-token";
      };
      env = {
        LLAMA_CPP_ENDPOINT = "http://petunia.home.lan:8000";
      };

      homeFiles =
        let
          bvFiles = ../home-files/bv;
        in
        {
          ".mcporter/mcporter.json".source = bvFiles + "/.mcporter/mcporter.json";
          ".pi/agent/models.json".source = models.piModelsJson;
          ".bv-logic/notify.json".source = bvFiles + "/bv/notify.json";
          # Builder agent dir — Pi reads PI_CODING_AGENT_DIR to find these
          ".bv-logic/builder/AGENTS.md".source = bvFiles + "/bv/builder/AGENTS.md";
          ".bv-logic/builder/models.json".source = models.piModelsJson;
          ".bv-logic/builder/extensions/bash-lockdown.ts".source =
            bvFiles + "/bv/builder/extensions/bash-lockdown.ts";
          ".bv-logic/builder/skills/prime.md".source = bvFiles + "/bv/builder/skills/prime.md";
          ".bv-logic/builder/skills/mcporter.md".source = bvFiles + "/bv/builder/skills/mcporter.md";
          # Verifier agent dir
          ".bv-logic/verifier/AGENTS.md".source = bvFiles + "/bv/verifier/AGENTS.md";
          ".bv-logic/verifier/models.json".source = models.piModelsJson;
          ".bv-logic/verifier/extensions/verifier-provider.ts".source =
            bvFiles + "/bv/verifier/extensions/verifier-provider.ts";
          ".bv-logic/verifier/extensions/readonly-enforcer.ts".source =
            bvFiles + "/bv/verifier/extensions/readonly-enforcer.ts";
          ".bv-logic/orchestrator/package.json".source = bvFiles + "/bv/orchestrator/package.json";
          ".bv-logic/orchestrator/tsconfig.json".source = bvFiles + "/bv/orchestrator/tsconfig.json";
          ".bv-logic/orchestrator/coordinator.sh" = {
            source = bvFiles + "/bv/orchestrator/coordinator.sh";
            executable = true;
          };
          ".bv-logic/orchestrator/init-bv.sh" = {
            source = bvFiles + "/bv/orchestrator/init-bv.sh";
            executable = true;
          };
          ".bv-logic/orchestrator/orchestrator.ts".source = bvFiles + "/bv/orchestrator/orchestrator.ts";
          ".bv-logic/orchestrator/notify.ts".source = bvFiles + "/bv/orchestrator/notify.ts";
          ".bv-logic/orchestrator/notify-config.ts".source = bvFiles + "/bv/orchestrator/notify-config.ts";
          ".bv-logic/orchestrator/command-listener.ts".source =
            bvFiles + "/bv/orchestrator/command-listener.ts";
        };
    };

    antigravity = {
      name = "antigravity";
      tapId = "agrav";
      ip = "192.168.33.12";
      mac = "02:00:00:00:00:12";
      vsockCid = 12;
      extraPackages = [ pkgs.antigravity-cli ];
    };

    dsh = {
      name = "dsh";
      tapId = "dsh";
      ip = "192.168.33.17";
      mac = "02:00:00:00:00:17";
      vsockCid = 17;

      # No persistentShares. Nothing of this guest's own reaches the host: its
      # whole configuration is generated from Nix in modules/dsh.nix and copied
      # into the ephemeral home on every boot, so there is nothing to carry
      # across and nothing to keep in sync with a host dotfile.

      extraPackages = [
        inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.dsh
        # `dsh plugin ... add <pkg>` forwards to pnpm, which has to be on PATH
        # for optional bundles (the subagent-codex and subagent-claude-code
        # providers, a third-party TUI) to be installable at all.
        pkgs.pnpm
        # dsh-model edits the patch file in place.
        pkgs.yq-go
      ]
      ++ mcpServers;

      extraModules = [
        { _module.args.guestIp = "192.168.33.17"; }
        ./dsh.nix
      ];

      env = {
        # The microvm is the isolation boundary, so dsh's own sandbox is off and
        # nothing prompts for approval. bwrap is deliberately absent for the
        # same reason.
        DSH_PERMISSION_MODE = "danger-full-access";

        # Telemetry is off by default, but this also suppresses the anonymous
        # user id that would otherwise be stamped on every provider request —
        # including the ones going to our own endpoint. Any non-empty value is
        # an authoritative opt-out.
        DSH_TELEMETRY_DISABLED = "1";

        # The endpoint wants no key, but the adapter still resolves the
        # variable named by apiKeyEnv and errors when it is unset.
        VLLM_API_KEY = "not-required";
      };
    };

    crush = {
      name = "crush";
      tapId = "crush";
      ip = "192.168.33.15";
      mac = "02:00:00:00:00:15";
      vsockCid = 15;
      persistentShares = [
        {
          host = ".config/crush";
          guest = ".config/crush";
        }
        {
          host = ".local/share/crush";
          guest = ".local/share/crush";
        }
      ];
      extraPackages = [ inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.crush ];
    };
  };

  allSpecs = lib.attrValues specs;
  allTapIds = map (s: s.tapId) allSpecs;
  allCids = map (s: s.vsockCid) allSpecs;

in
assert lib.assertMsg (builtins.all (id: builtins.stringLength id <= 7) allTapIds)
  "inventory: one or more tapId values exceed 7 characters (max for IFNAMSIZ with 'microvm-' prefix)";

assert lib.assertMsg (
  builtins.length allTapIds == builtins.length (lib.unique allTapIds)
) "inventory: duplicate tapId detected — each agent must have a unique tapId";

assert lib.assertMsg (
  builtins.length allCids == builtins.length (lib.unique allCids)
) "inventory: duplicate vsockCid detected — each agent must have a unique vsockCid";

specs
