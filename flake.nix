{
  description = "Project Permafrost: Isolated Agent Sandbox Architecture on NixOS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    flake-parts.url = "github:hercules-ci/flake-parts";

    # Every .nix file under ./modules is a flake-parts module, discovered rather
    # than listed. Adding a harness or a guest concern is adding a file — but the
    # failure mode is silence, so see the notes in modules/flake/systems.nix and
    # modules/guest/module-list.nix before moving anything.
    import-tree.url = "github:vic/import-tree";

    microvm = {
      url = "github:astro/microvm.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # AI Coding Agents
    llm-agents = {
      url = "github:numtide/llm-agents.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Curated Agent Skills — a directory per skill, each with a SKILL.md whose
    # YAML frontmatter carries `name` and `description`. Harnesses that support
    # the format discover them by scanning a directory, so this is plain content
    # rather than a flake.
    #
    # Site-specific and private: evaluating this flake needs ssh to the gitea
    # behind code-ssh.novuscotia.com. Drop the input and the skills copy in
    # modules/harness/dsh.nix in a fork.
    agent-skills = {
      url = "github:mister2d/agent-skills/main";
      flake = false;
    };

    # Devenv — Fast, Declarative, Reproducible, and Composable Developer Environments using Nix
    devenv = {
      url = "github:cachix/devenv";
    };

    # System-wide theming. Tracks master rather than a release branch, since
    # this flake is on nixos-unstable.
    stylix = {
      url = "github:nix-community/stylix";
      inputs.nixpkgs.follows = "nixpkgs";
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

  # Everything else — systems, perSystem, the host and the guest — lives in a
  # module file under ./modules. Nothing is configured here.
  outputs = inputs: inputs.flake-parts.lib.mkFlake { inherit inputs; } (inputs.import-tree ./modules);
}
