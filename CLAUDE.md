# AGENTS.md

> **Purpose.** This document is the single authoritative guide for any AI coding
> agent maintaining, extending, or debugging. It is a living reference,
> not a one-time task list. Every task — from adding a package to onboarding a new
> host — must be grounded in the rules and verification steps here.
>
> For factual NixOS data (package names, option paths, versions, Home Manager options),
> you have the `nixos-tools` MCP server. Use it. Do not rely on training-data memory of
> nixpkgs — it drifts by months.

---

## 0. Steering authorities

When this document and an upstream reference conflict, **the upstream reference
wins**. Stop and report the conflict; do not improvise.

| Authority | Where to fetch | Governs |
|---|---|---|
| Dendritic pattern | `https://github.com/mightyiam/dendritic` | `flake.modules.*` namespace, deferred module merge semantics |
| flake-parts manual | `https://flake.parts/` | Option namespacing, `perSystem`, module system rules |
| import-tree README | `https://github.com/vic/import-tree` | Builder API: `addPath`, `filter`, `result` |
| NixOS manual | Use `nixos-tools` MCP (see §2) | NixOS options, module patterns, `lib.*` functions |
| Home Manager manual | Use `nixos-tools` MCP (see §2) | HM options and module patterns |

Use the `fetch` MCP tool to re-read any authority URL before making structural
changes. Do not rely on training-data memory of any of these projects.

---

## 1. The nixos-tools MCP server — your factual grounding tool

**Use `nixos-tools` before asserting any fact about nixpkgs, NixOS, or Home
Manager.** Training data lags nixpkgs by months. An attribute path, option name,
or package version that seems right from memory may be renamed, removed, or
split. Always verify.

### When to use it

| Situation | What to query |
|---|---|
| Adding a package — need the exact attribute path | `nix` → `action: search`, `query: <package-name>` |
| Enabling a NixOS service — need the option path | `nix` → `action: search`, `type: options`, `query: <service-name>` |
| Adding a Home Manager option | `nix` → `action: search`, `source: home-manager`, `query: <topic>` |
| Checking which nixpkgs channel has a version | `nix_versions` → `package: <attr>`, `version: <ver>` |
| Looking up NixOS wiki guidance | `nix` → `action: search`, `source: nixos-wiki`, `query: <topic>` |
| Finding nix.dev tutorials or examples | `nix` → `action: search`, `source: nix.dev`, `query: <topic>` |
| Confirming a package is in the binary cache | `nix` → `action: cache`, `query: <attr>` |

### Concrete query examples (copy these shapes exactly)

```json
// Find a package by name
{ "action": "search", "query": "tailscale" }

// Find a NixOS option for a service
{ "action": "search", "type": "options", "query": "services.synapse" }

// Find a Home Manager option
{ "action": "search", "source": "home-manager", "query": "programs.git" }

// Check version history — which nixpkgs commit shipped version X?
// nix_versions tool:
{ "package": "tailscale", "version": "1.80.0" }

// Check binary cache availability
{ "action": "cache", "query": "python312" }

// Read the NixOS wiki page on a topic
{ "action": "search", "source": "nixos-wiki", "query": "ZFS" }

// Find nix.dev tutorials
{ "action": "search", "source": "nix.dev", "query": "flake inputs" }
```

**Rule:** If you are about to write a package attribute path, NixOS option path,
or Home Manager option path that you did not just verify with `nixos-tools` in
this session, stop and verify it first.

---

## 2. Universal operating rules

Follow these on every task, every commit:

1. **Read before asserting.** If you have not opened a file in this session, you
   do not know its contents. Use `Read` before editing, `ls` before claiming a
   directory structure.

2. **Verify with `nixos-tools` before writing any package or option path.** Never
   write `pkgs.somePackage` or `services.something.enable` from memory alone.
   Query `nixos-tools` first (see §1).

3. **One logical change per commit.** Do not batch unrelated edits. Linting and
   closure verification are per-commit.

4. **Lint before committing:**
   ```bash
   nix develop --command pre-commit run --files <space-separated changed files>
   ```
   All three hooks must pass: `nixfmt` (formatting, RFC 166 style), `deadnix`
   (unused bindings), `statix` (Nix anti-patterns).

   This command is the authority for linting — do not substitute `devenv shell`
   for it. `devenv.nix` at the repo root exists for interactive convenience
   (devenv's native activation enters it on `cd`, after a one-time
   `devenv allow`), and it deliberately declares no git hooks: the flake's
   `pre-commit-hooks` module owns `.pre-commit-config.yaml`, which is a tracked
   symlink into the store and would otherwise churn between the two shells.

5. **Evaluate after committing:**
   ```bash
   nix flake check
   ```
   This evaluates the full module tree for all hosts. Must pass green.

6. **Honest uncertainty.** If you cannot confirm a change is behavior-preserving,
   stop and report. A blocked task accurately described is better than a silently
   broken configuration.

7. **No invented patterns.** Every structural choice must trace to §0 authorities
   or the existing codebase. If the right approach is unclear, read the authority
   first. Gaps are open questions, not licence to fill from memory.

8. **Sub-agent / agent teams.** Decompose complex or cross-domain operations into
   discrete tasks and spawn specialized sub-agents to handle them. Scope each sub-
   agent's context strictly to its specific domain to prevent context pollution
   and hallucination. The primary agent must act as the orchestrator: assign clear
   objectives, review the output of each sub-agent against the acceptance criteria,
   and synthesize the isolated tasks into the final deliverable.

9. **Git worktree isolation.** Execute all non-trivial code modifications, parallel
   tasks, and sub-agent operations within dedicated `git worktree` environments. This
   strictly isolates state changes, dependencies, and file locks, preventing disruption
   to the primary working directory. Ensure commits generated within the worktree are
   atomic, logically grouped, and tied directly to the worktree's specific objective.
   The orchestrating agent is responsible for validating the worktree's state, handing
   the merge back to the target branch, and pruning the worktree upon sucessful integration.
---

