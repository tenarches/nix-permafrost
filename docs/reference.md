# Permafrost Technical Reference

This document serves as a densely packed technical reference for the underlying architecture, module definitions, and hypervisor constraints of Project Permafrost.

## The `cloud-hypervisor` Backend

We specifically target `cloud-hypervisor` (Rust-based) over QEMU to minimize the virtualization attack surface while retaining critical features like `virtiofs`.

### Networking
Unlike user-mode SLIRP networking (which `cloud-hypervisor` does not support), Permafrost uses `tap` interfaces. This is why `sudo` is required to launch the guest: the host must create and configure the `tap` device (`microvm-pf`, from `permafrost.identity.tapId = "pf"`) to route traffic to the external `wlp4s0` interface via the `microbr` bridge. The `microvm-` prefix is not cosmetic — the host's bridge network matches `matchConfig.Name = "microvm*"`, and a tap named anything else is created but never attached to `microbr`.

## The `modules/` Tree

There is no central registry file. `flake.nix` is `mkFlake { inherit inputs; }
(inputs.import-tree ./modules)` and nothing else — every `.nix` file under `modules/` is
discovered automatically and, unless its path contains a `/_` segment, treated as a
flake-parts module. Each module contributes to `flake.modules.<class>.<name>`, a namespace
declared once (`modules/flake/modules.nix`, importing `flake-parts.flakeModules.modules`)
that merges rather than collides — this is the [dendritic
pattern](https://github.com/mightyiam/dendritic).

```
modules/
├── flake/          perSystem infra: nixpkgs overlays, systems, dev shell, formatter, pre-commit
├── guest/          flake.modules.nixos.guest-*  — what the guest always is
│   └── home/       flake.modules.homeManager.agent-*  — the guest's one user's HM config
├── harness/        flake.modules.nixos.harness-*  — one file per agent CLI
├── host/           flake.modules.nixos.host-*  — the bridge, secrets, the fleet unit
├── packages/       perSystem packages.*  — permafrost, status, gc, ssh-config
├── _lib/           plain Nix, not modules — models.nix, shares.nix
└── _pkgs/          plain Nix, not modules — runner.nix, tools.nix, openclaude.nix, crosvm-graphics.nix
```

`import-tree` skips any path with a `/_` component, which is why `_lib` and `_pkgs` hold
importable functions and derivations rather than flake-parts modules — the naming is a
signal, not a filesystem trick.

### The `guest-*` / `harness-*` naming convention

A guest-wide concern (identity, shares, storage, the user, home-manager wiring) is
`flake.modules.nixos.guest-<name>`. An agent CLI is `flake.modules.nixos.harness-<name>`.
`modules/guest/module-list.nix` filters `config.flake.modules.nixos` for either prefix into
`flake.lib.guestModules`, the one list both launch paths import:

```nix
# modules/guest/module-list.nix
flake.lib.guestModules = lib.attrValues (
  lib.filterAttrs (
    name: _: lib.hasPrefix "guest-" name || lib.hasPrefix "harness-" name
  ) config.flake.modules.nixos
);
```

A standard harness definition looks like this — the whole of `modules/harness/opencode.nix`:

```nix
{ inputs, ... }:
{
  flake.modules.nixos.harness-opencode =
    { pkgs, ... }:
    {
      environment.systemPackages = [
        inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.opencode
      ];

      permafrost.shares = [
        { host = ".config/opencode"; guest = ".config/opencode"; }
      ];
    };
}
```

`permafrost.shares` (option declared in `modules/guest/shares.nix`) is what each harness
writes into rather than a central list being edited: `host` is a path relative to the
launching user's home, `guest` is where it lands under `/home/agent` (also the name under
`/mnt/persist` and the input to the virtiofs tag, so it must be unique), and an optional
`link` adds one more symlink for a harness that wants a single file rather than the whole
directory — `.claude.json`, linking into the `.claude-config` share, is the example in
`modules/harness/claude.nix`.

**Adding an agent is adding one file.** Nothing central needs editing: name the module
`harness-<name>`, and `module-list.nix` picks it up on its own — the failure mode of typoing
the prefix is silence (the module simply never reaches `guestModules`), not an evaluation
error, so double-check the prefix.

*Note: `openclaude` is still vendored locally (`modules/_pkgs/openclaude.nix`) rather than
pulled from an external upstream flake, for hermetic reliability.*

## Secret Injection Architecture — as designed, not as built

Handling secrets securely in declarative VMs is notoriously difficult. Permafrost's design
avoids baking secrets into the Nix store, but as built today only the host half of that
design is wired up:

1. **Host-Side Decryption (real).** The host unseals secrets (e.g., `anthropic-api-key`,
   `google-api-key`, via `sops-nix` and a TPM-sealed age key) to `/run/secrets/*`. This is
   declared in `modules/host/secrets.nix` and does run.
2. **The `extraArgsScript` route (present, but inert).** `cloud-hypervisor` lacks native
   parsing for `microvm.credentialFiles`. `modules/guest/base.nix`'s `extraArgsScript` reads
   the host secrets named there and dynamically constructs the `--platform
   oem_string=[...]` argument cloud-hypervisor accepts instead. It is gated on
   `mcfg.credentialFiles != { }` — and nothing in this tree ever sets
   `microvm.credentialFiles`, so the gate never opens and this code never runs.
3. **Guest Consumption (never reached).** In principle the guest kernel would read the OEM
   strings and `systemd` would mount them to `/run/host/credentials/` for the agent process
   to consume. Since step 2 never fires, no credential reaches the guest by this route
   today. A harness that needs a credential gets it some other way — `dsh`'s endpoint takes
   no key at all, for instance.

The machinery is kept rather than removed because it is the only credential route
cloud-hypervisor currently offers and rediscovering it would be expensive — but treat it as
a documented gap, not a working pipeline, until something actually populates
`microvm.credentialFiles`.
