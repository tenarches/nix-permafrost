# Replace Nixvim Configuration and Adopt MCP Overlay Pattern from nix-nexus

## Problem

The `opencode-agent` MicroVM build has two failures:

1. **Gruvbox source fetch failure**: The gruvbox.nvim colorscheme plugin requires fetching a source tarball from GitHub, which fails due to SSL certificate verification and DNS resolution errors. The entire build cascade collapses from this single fetch failure.

2. **fastmcp test hang** (revealed after fixing gruvbox): `python3.13-fastmcp-2.14.5` hangs indefinitely during `pytestCheckPhase` on `test_sampling_tool.py`. The sampling tests require async server communication unavailable in the Nix build sandbox. This package is a transitive dependency of MCP server packages from `mcp-servers-nix`, and the hang occurs because `mcp-servers-nix.inputs.nixpkgs.follows = "nixpkgs"` forces evaluation against nixos-unstable.

## Solution

Two changes that mirror nix-nexus patterns:

1. **Replace nixvim/neovim configuration**: Substitute the nightfox/carbonfox colorscheme for gruvbox. Upgrade the editor from a minimal config to a production-grade setup with completion, file navigation, git integration, and broader LSP coverage.

2. **Adopt nix-nexus MCP overlay pattern**: Switch MCP server consumption from direct flake package access (`inputs.mcp-servers-nix.packages`) to the overlay approach (`inputs.mcp-servers-nix.overlays.default`). Add a `buildFixesOverlay` that disables `fastmcp` tests before the MCP overlay evaluates. This gives control over transitive Python dependencies and prevents future test-hang breakage.

## Reference

Source of truth: https://github.com/tenarches/nix-nexus.git — specifically `flake.nix`, `modules/user/home.nix`, and `modules/user/neovim-home.nix`.

## Changes

### 1. modules/agent-base.nix

Move the `inputs.nixvim.homeModules.nixvim` import from `modules/programs/nixvim.nix` up to the home-manager user imports in `agent-base.nix`. This matches the nix-nexus pattern where the nixvim home module is loaded at the integration point, separate from the editor configuration.

Before:
```nix
users.agent = {
  imports = [ ./programs/nixvim.nix ];
};
```

After:
```nix
users.agent = {
  imports = [
    inputs.nixvim.homeModules.nixvim
    ./programs/nixvim.nix
  ];
};
```

### 2. modules/programs/nixvim.nix

Full replacement. Remove the inline nixvim module import and `inputs` dependency. Replace the entire `programs.nixvim` configuration with the nix-nexus `neovim-home.nix` content, minus the `extraPlugins` block (vim-nomad is not relevant to agent VMs) and the empty `extraConfigLua` placeholder.

#### Colorscheme
- nightfox with carbonfox flavor (replaces gruvbox)

#### Options
- dark background, 2-space indentation, smart indent
- No line numbers (matches nix-nexus preference)
- Cursorline, scrolloff 8, termguicolors
- Full mouse support in all modes

#### Clipboard
- Register: unnamedplus
- Provider: wl-copy (agents have Wayland support via virtiofs)

#### Keymaps
- Right-click paste from system clipboard (normal, visual, insert, command modes)
- Ctrl+D/U: centered half-page movements
- Ctrl+J/K: 8-line jumps (normal and visual modes)

#### LSP Servers
- nixd (Nix — replaces nil_ls)
- terraformls (HCL/Terraform)
- yamlls (YAML)
- jsonls (JSON)
- taplo (TOML)
- bashls (Shell scripting)

#### Completion Engine (cmp)
- Sources: nvim_lsp, path, buffer, luasnip
- Supporting plugins: cmp-nvim-lsp, cmp-buffer, cmp-path, cmp_luasnip
- Mappings: Ctrl+Space (complete), Tab/Shift-Tab (navigate), Enter (confirm), Ctrl+E (close), Ctrl+D/F (scroll docs)

#### Treesitter
- Highlight and indent enabled

#### Productivity Plugins
- telescope (fuzzy finder)
- lualine (status line)
- neo-tree (file navigator)
- gitsigns (git integration)
- which-key (keybinding discovery)
- web-devicons (file type icons)

#### Aliases
- viAlias = true
- vimAlias = true

### 3. flake.nix — Add buildFixesOverlay and MCP overlay

Add two overlays to the permafrost NixOS configuration, mirroring the nix-nexus pattern:

```nix
# In nixosConfigurations.permafrost modules:
{
  nixpkgs.overlays = [
    # Fix Python package test failures in MCP dependency chain
    (_: prev: {
      pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
        (_: pyPrev: {
          fastmcp = pyPrev.fastmcp.overridePythonAttrs { doCheck = false; };
        })
      ];
    })
    # MCP server packages — evaluated against patched pkgs
    inputs.mcp-servers-nix.overlays.default
  ];
}
```

The build fix overlay disables `fastmcp` tests. The mcp-servers-nix overlay then evaluates against the patched pkgs, so `context7-mcp` and `mcp-server-time` build without hanging.

### 4. modules/inventory.nix — Switch to overlay-based MCP consumption

Change MCP server references from direct flake package access to pkgs (populated by the overlay):

Before:
```nix
mcpServers = [
  inputs.mcp-servers-nix.packages.${pkgs.stdenv.hostPlatform.system}.context7-mcp
  inputs.mcp-servers-nix.packages.${pkgs.stdenv.hostPlatform.system}.mcp-server-time
  pkgs.github-mcp-server
  pkgs.terraform-mcp-server
  pkgs.mcp-nixos
];
```

After:
```nix
mcpServers = [
  pkgs.context7-mcp
  pkgs.mcp-server-time
  pkgs.github-mcp-server
  pkgs.terraform-mcp-server
  pkgs.mcp-nixos
];
```

The `inputs` argument can be removed from this file's function signature since it's no longer needed (MCP packages come from pkgs, LLM agent packages are passed through extraPackages from agents.nix or remain as inputs).

Note: `inputs` is still needed in runners.nix for `inputs.llm-agents.packages` references. Only the MCP lines change.

## What Does Not Change

- The nixvim flake input (`github:nix-community/nixvim/nixos-25.11`) — already identical to nix-nexus
- The mcp-servers-nix flake input URL and `follows` — the overlay approach works with the existing `follows = "nixpkgs"`
- `modules/agents.nix` — still passes `pkgs` to inventory.nix, which now picks up MCP packages from the overlay
- No new files created

## Decisions

- **vim-nomad dropped**: Not relevant to agent VM workflows (per user decision)
- **extraConfigLua dropped**: nix-nexus has only an empty placeholder comment; not needed
- **pyright dropped**: Current config has pyright for Python LSP; nix-nexus does not include it. Mirroring nix-nexus exactly means dropping it. Python LSP can be re-added later if agents need it.
- **Overlay over direct packages**: Direct flake package access is opaque — you can't patch transitive dependencies. The overlay evaluates against your pkgs, so build fixes propagate through the entire dependency chain.
