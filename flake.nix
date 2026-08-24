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

    # Pinned solely for `crosvm`, the host-side vhost-user GPU device behind
    # microvm.graphics. It must speak the same vhost-user dialect as the
    # Spectrum-patched cloud-hypervisor that microvm.nix pairs it with, and
    # those two have diverged: the fork asks for GET_SHARED_MEMORY_REGIONS
    # (message 1004, protocol bit 0x8000_0000), which crosvm has since replaced
    # with the standardized SHMEM_MAP (bit 0x0020_0000). Current crosvm has no
    # handler for 1004 and drops the connection, so the VM dies with
    # VhostUserGetSharedMemoryRegions(Disconnected). 25.05's crosvm still
    # implements the old message and bit — verified in
    # third_party/vmm_vhost/src/message.rs.
    #
    # Deliberately NOT following nixpkgs: the point is the older tree.
    # Remove once Spectrum's fork moves to SHMEM_MAP.
    nixpkgs-crosvm.url = "github:NixOS/nixpkgs/nixos-25.05";

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
      url = "git+ssh://gitea@code-ssh.novuscotia.com/ddukes/agent-skills.git?ref=main";
      flake = false;
    };

    # MCP Server Framework
    mcp-servers-nix = {
      url = "github:natsukium/mcp-servers-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Devenv 2.2 — native shell activation via `devenv hook`
    devenv = {
      url = "github:cachix/devenv/v2.2.1";
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
