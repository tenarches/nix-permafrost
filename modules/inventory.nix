{ inputs, pkgs, ... }:

let
  inherit (pkgs) lib;

  openclaude = pkgs.callPackage ./programs/openclaude.nix { };
  mcpServers = [
    pkgs.context7-mcp
    pkgs.mcp-server-time
    pkgs.github-mcp-server
    pkgs.terraform-mcp-server
    pkgs.mcp-nixos
  ];

  specs = {
    claude = {
      name = "claude";
      tapId = "claude";
      ip = "192.168.33.10";
      mac = "02:00:00:00:00:10";
      vsockCid = 10;
      workspacePath = "/run/agent-workspaces/claude";
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

    gemini = {
      name = "gemini";
      tapId = "gemini";
      ip = "192.168.33.11";
      mac = "02:00:00:00:00:11";
      vsockCid = 11;
      workspacePath = "/run/agent-workspaces/gemini";
      persistentShares = [
        {
          host = ".gemini";
          guest = ".gemini";
        }
      ];
      extraPackages = [
        inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.gemini-cli
      ]
      ++ mcpServers;
      credentials = {
        GOOGLE_API_KEY = "/run/secrets/google-api-key";
      };
    };

    opencode = {
      name = "opencode";
      tapId = "ocode";
      ip = "192.168.33.13";
      mac = "02:00:00:00:00:13";
      vsockCid = 13;
      workspacePath = "/run/agent-workspaces/opencode";
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
      workspacePath = "/run/agent-workspaces/pi";
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
    };

    bv = {
      name = "bv";
      tapId = "bv";
      ip = "192.168.33.16";
      mac = "02:00:00:00:00:16";
      vsockCid = 16;
      workspacePath = "/run/agent-workspaces/bv";
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
      extraPackages = [
        inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.pi
        inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.mcporter
        pkgs.nodejs_25
        pkgs.tsx
      ]
      ++ mcpServers;
      credentials = {
        GITHUB_TOKEN = "/run/secrets/github-token";
      };
      env = {
        LLAMA_CPP_ENDPOINT = "http://dualie.home.lan:8001";
        PI_CODING_AGENT_SESSION_DIR = "/home/agent/bv/sessions";
      };

      homeFiles =
        let
          bvFiles = ../home-files/bv;
        in
        {
          ".mcporter/mcporter.json".source = bvFiles + "/.mcporter/mcporter.json";
          ".pi/agent/models.json".source = bvFiles + "/.pi/agent/models.json";
          ".bv-logic/notify.json".source = bvFiles + "/bv/notify.json";
          ".bv-logic/builder/AGENTS.md".source = bvFiles + "/bv/builder/AGENTS.md";
          ".bv-logic/builder/.pi/extensions/bash-lockdown.ts".source =
            bvFiles + "/bv/builder/.pi/extensions/bash-lockdown.ts";
          ".bv-logic/builder/.pi/skills/prime.md".source = bvFiles + "/bv/builder/.pi/skills/prime.md";
          ".bv-logic/builder/.pi/skills/mcporter.md".source = bvFiles + "/bv/builder/.pi/skills/mcporter.md";
          ".bv-logic/verifier/AGENTS.md".source = bvFiles + "/bv/verifier/AGENTS.md";
          ".bv-logic/verifier/.pi/extensions/verifier-provider.ts".source =
            bvFiles + "/bv/verifier/.pi/extensions/verifier-provider.ts";
          ".bv-logic/verifier/.pi/extensions/readonly-enforcer.ts".source =
            bvFiles + "/bv/verifier/.pi/extensions/readonly-enforcer.ts";
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
      workspacePath = "/run/agent-workspaces/antigravity";
      persistentShares = [
        {
          host = ".gemini";
          guest = ".gemini";
        }
      ];
      gui = true;
      extraPackages = [ pkgs.antigravity ];
    };

    crush = {
      name = "crush";
      tapId = "crush";
      ip = "192.168.33.15";
      mac = "02:00:00:00:00:15";
      vsockCid = 15;
      workspacePath = "/run/agent-workspaces/crush";
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
