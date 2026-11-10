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

*Note: `openclaude` is vendored locally (`modules/_pkgs/openclaude.nix`) rather than pulled
from an external upstream flake, for hermetic reliability. That is a packaging detail only —
`harness/openclaude.nix` is a harness module like any other, declaring its own packages and
its own shares.*

## Guest accounts

The guest has two logins that run commands. Both are declared in `modules/guest/`.

| Account | uid / gid | Home | Reaches the host through | Login |
|---|---|---|---|---|
| `agent` | 1000 / `users` | `/home/agent`, the `home.img` volume | the shares under `/mnt/persist`, linked into its home | serial console, ssh with the launching user's keys, ssh with a CA certificate |
| `adurable` | 1001 / 1001 (`adurable`) | `/home/adurable`, the `adurable-home.img` volume | nothing | ssh with a CA certificate only |

`agent` is the account of the owner's harnesses (`modules/harness/*.nix`). Their sign-in
files are the virtiofs shares, and the launch credentials are in `/run/launch`. Anything
that reads untrusted text must not run as `agent`.

`adurable` (`modules/guest/adurable.nix`) is the account pi-durable runs its model tool
commands as:

- **No key, no password.** The password is locked (`!`). `AuthorizedKeysFile none` and
  `AllowAgentForwarding no` apply to it in a `Match User adurable` block, so the keys the
  runner harvests for `agent` and any `~/.ssh/authorized_keys` it writes do not log in. A
  certificate does, when one of its principals is `adurable`. That is sshd's default rule
  (no `AuthorizedPrincipalsFile`, see `modules/guest/ssh-ca.nix`), so a certificate for
  `agent` or `root` does not log in as `adurable`, and the reverse. The Vault SSH CA role
  that signs for it is `ssh-client-signer/sign/durable`.
- **No groups.** Its primary group is its own. It is not in `users`, `video`, `render`,
  `systemd-journal` or `wheel`.
- **No share.** There is no virtiofs share and nothing under `/mnt/persist` for it. Its home
  is a disk volume recreated on every boot, so what it writes goes when the VM stops. The
  home is mode 0700, and `tmpfiles` creates `work` and `workspaces` in it.
- **Closed to it:** `/home/agent` is 0700. `/mnt/persist` is 0700 and owned by `agent`
  (`modules/guest/shares.nix`), so a share cannot be reached by path whatever mode its host
  directory has. `/run/launch` is a virtiofs share whose host directory the runner makes
  0700, so only root reads it.
- **Nix.** `nix.settings.allowed-users` lists `agent` and `adurable`, so both can use the
  daemon. `trusted-users` stays `root`. `git`, `bash` and `nix` are on its `PATH` from the
  system packages.

Not done: `/proc` is not mounted with `hidepid`, so `adurable` can list the processes of
`agent`. NixOS removed its `security.hideProcessInformation` module because the mount option
breaks cgroups v2 session tracking, and systemd does not support it as a global setting.
It needs a boot test of the guest before it is added.

One local service is reachable by every account: the dsh web UI listens on
`127.0.0.1:3080` (`modules/harness/dsh.nix` sets the port), and any local user can connect.
Its browser login is a signed cookie. The one-time token that starts it is printed to the
journal of `dsh-web`, which `adurable` cannot read (it is not in `systemd-journal`). The
`/api` Host check accepts loopback, and that is a check on the Host header, not a login.
Whether a loopback request without the cookie is refused is not verified. The tailscale
daemon socket is also open to every account, with read-only status for any account that
is not root.

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
