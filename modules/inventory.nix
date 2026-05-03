{
  inputs,
  pkgs,
  ...
}:

let
  openclaude = pkgs.callPackage ./programs/openclaude.nix { };
  mcpServers = [
    pkgs.context7-mcp
    pkgs.mcp-server-time
    pkgs.github-mcp-server
    pkgs.terraform-mcp-server
    pkgs.mcp-nixos
  ];
in
{
  claude = {
    name = "claude";
    ip = "192.168.33.10";
    mac = "02:00:00:00:00:10";
    vsockCid = 10;
    workspacePath = "/run/agent-workspaces/claude";
    persistentShares = [
      {
        host = ".claude";
        guest = ".claude";
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
    extraPackages = [ inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.pi ];
  };

  antigravity = {
    name = "antigravity";
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
    extraPackages = [
      inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.crush
    ];
  };
}
