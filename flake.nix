{
  description = "Project Permafrost: Isolated Agent Sandbox Architecture on NixOS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    flake-parts.url = "github:hercules-ci/flake-parts";

    microvm = {
      url = "github:astro/microvm.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # AI Coding Agents
    llm-agents = {
      url = "github:numtide/llm-agents.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # MCP Server Framework
    mcp-servers-nix = {
      url = "github:natsukium/mcp-servers-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Devenv 2.0 for native development environments
    devenv = {
      url = "github:cachix/devenv";
    };

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Nixvim - Neovim configuration via Nix
    nixvim = {
      url = "github:nix-community/nixvim";
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Declarative Git Hooks
    pre-commit-hooks = {
      url = "github:cachix/pre-commit-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

  };

  outputs =
    inputs@{
      nixpkgs,
      flake-parts,
      microvm,
      pre-commit-hooks,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [ pre-commit-hooks.flakeModule ];

      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      perSystem =
        {
          config,
          pkgs,
          system,
          ...
        }:
        {
          formatter = pkgs.nixfmt;

          pre-commit.settings.hooks = {
            nixfmt.enable = true;
            deadnix.enable = true;
            statix.enable = true;
          };

          devShells.default = pkgs.mkShell {
            shellHook = config.pre-commit.installationScript;
            packages = [
              inputs.devenv.packages.${system}.devenv
              pkgs.sops
              pkgs.age
              pkgs.virtiofsd
              config.pre-commit.settings.package
            ];
          };

          # Export MicroVM runners as packages
          packages = import ./runners.nix { inherit inputs system; };
        };

      flake = {
        nixosConfigurations.permafrost = nixpkgs.lib.nixosSystem {
          specialArgs = { inherit inputs; };
          modules = [
            # Host configuration
            ./modules/host.nix
            ./modules/secrets.nix
            ./modules/agents.nix

            # MicroVM host module
            microvm.nixosModules.host

            {
              nixpkgs = {
                overlays = [
                  # Centralized Python MCP overrides
                  (import ./overlays/python-mcp.nix)
                  # MCP server packages — evaluated against patched pkgs
                  inputs.mcp-servers-nix.overlays.default
                ];
                config.allowUnfree = true;
                hostPlatform.system = "x86_64-linux";
              };
              networking.hostName = "permafrost";
              system.stateVersion = "25.11";

              # Minimal config to pass nix flake check
              fileSystems."/" = {
                device = "tmpfs";
                fsType = "tmpfs";
              };
              boot.loader.grub.enable = false;
              boot.loader.generic-extlinux-compatible.enable = true;

              # Example user
              users.users.agent = {
                isNormalUser = true;
                extraGroups = [
                  "wheel"
                  "networkmanager"
                  "microvm"
                ];
              };
            }
          ];
        };

        # Reusable modules
        nixosModules = {
          agent-base = ./modules/agent-base.nix;
          host-bridge = ./modules/host.nix;
        };
      };
    };
}
