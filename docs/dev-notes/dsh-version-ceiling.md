# Dev note: why dsh is pinned at 0.1.5-rc.3

Written 2026-09-29. Everything under **Verified** was run on this host against
the artifacts named; **Inferred** and **Untested** are labelled as such.

## TL;DR

- `modules/_pkgs/dsh.nix` vendors `@deepseek-ai/dsh` **0.1.5-rc.3**. This is the
  newest release that boots on nixpkgs' Node. It is a ceiling, not a preference.
- Every release from **0.1.6 on** — including npm's `latest` tag (0.1.7-rc.2) and
  the newest, 0.2.0-rc.1 — crashes at boot.
- `nix build` and `dsh --version` **pass on the crashing releases**. The only
  real test is booting `dsh web` (procedure below).

## The failure

```
dsh: fatal uncaught exception: Error: dsh: host preparation failed:
node-addon-require-builtin unsupported: Unsupported/no-getter
(x64 sysv getter is not a recognized this->field accessor ...)
    at internalModules (.../dsh-app-boot/lib/index.js)
    at installRuntimeInterception (...)
```

dsh-app-boot calls `node-addon-require-builtin` to reach Node internals
(`internal/modules/esm/loader`, `cjs/loader`, …) and install a module-resolution
interception. The addon finds V8/Node internals by pattern-matching the machine
code of a getter in the running `node` binary. nixpkgs' build of Node does not
match what version 0.1.6 of the addon recognises (it was presumably developed
against official Node binaries — **inferred**, not confirmed).

## Version matrix

Range of `node-addon-require-builtin` in each release's `dependencies`
(`npm view @deepseek-ai/dsh@<v> dependencies.node-addon-require-builtin`):

| dsh | addon range | boots on nixpkgs Node? |
|---|---|---|
| 0.1.5-rc.2 | (locked at 0.1.5) | yes (was the previous pin) |
| **0.1.5-rc.3** | `^0.1.4`, **locked 0.1.5** | **yes — verified, current pin** |
| 0.1.6-alpha.2, 0.1.7-alpha.1, 0.1.7-rc.1, 0.1.7-rc.2 | `^0.1.6` | not run; same addon as below, inferred no |
| 0.2.0-rc.1 | `^0.1.6` | **no — verified** |

0.2.0-rc.1 was tested on nixpkgs Node 22.23.2, 24.20.0 (the system one) and
26.5.0: identical failure on all three, so it is the build, not the version.
The `^0.1.6` releases cannot be pinned back to addon 0.1.5: the range excludes
it, and overriding upstream's manifest was deliberately not done.

## The trap inside 0.1.5-rc.3

Its range is `^0.1.4`, which **allows 0.1.6**. A lock generated from scratch
resolves the addon to **0.1.6** (verified: fresh lock → 0.1.6) and would crash.
`modules/_pkgs/dsh-lock.json` keeps 0.1.5 (and `node-addon-native-custom-loader`
0.1.5, `…-linux-x64-gnu` 0.1.5) only because it was regenerated *on top of* the
previous lock. Always seed the regeneration with the existing lock (step 3 in
the header of `dsh.nix`), then confirm:

```bash
jq -r '.packages | to_entries[]
  | select(.key|test("node-addon-require-builtin$")) | .value.version' \
  modules/_pkgs/dsh-lock.json          # must print 0.1.5
```

## Packaging facts (0.1.5-rc.3)

- The tarball still declares the unpublished devDependency
  `@deepseek-ai/dsh-experimental-code-runtime-python` (npm 404). `dsh.nix`
  strips it in `postPatch` and the lock must be generated against the stripped
  manifest. In **0.2.0-rc.1** it was renamed `…-ptc-runtime-python` and *is*
  published, so the strip becomes unnecessary once the ceiling lifts.
- `npmDepsHash` = `sha256-j/gSO99xyRzI4xl6radjhjVXZvOH4TjdTCDDSDjSVNY=`,
  source hash `sha256-SXfSkjOlkopO8cFuRL3BnXe7848Wgj1U7IfFsBmIML8=`.
- `"/bin/bash"` substitution in `dsh-terminal-bash` still applies (also checked
  in 0.2.0-rc.1: `DEFAULT_BASH_SHELL = "/bin/bash"`).
- CLI flags used by `harness/dsh.nix` still exist: `web --no-open --port
  --trusted-host` (`dsh web --help`).

## How to validate a dsh bump (the check that actually catches this)

`nix build .#permafrost` and `dsh --version` are **not sufficient**. From the
worktree, with a scratch config dir:

```bash
S=$(mktemp -d); mkdir -p $S/.dsh
# rendered configs: the store paths whose content mentions bifrost / vllm/Qwen3.8
cp <store>-dsh-settings.yaml    $S/.dsh/settings.yaml
cp <store>-dsh-cordis.patch.yml $S/.dsh/cordis.patch.yml; chmod u+w $S/.dsh/*

DSH_HOME=$S/.dsh DSH_PERMISSION_MODE=danger-full-access \
DSH_TELEMETRY_DISABLED=1 BIFROST_API_KEY=not-required \
  <dsh-out>/bin/dsh web --no-open --port 3199 &
```

Pass criteria, all observed on 0.1.5-rc.3:

1. Process stays up and prints `dsh web: http://127.0.0.1:3199/?token=…`
   (the crash occurs before this line).
2. `curl /` → 401 without the token; `curl -c jar "/?token=…"` → 303 + auth cookie;
   `curl -b jar /` then serves the SPA (index.html referencing
   `dsh-client-ui-settings-models`, `dsh-client-ui-model-selection`, …).
3. `dsh --profile web --dump-config` (same env) shows
   `agent-default-model` patched to `provider: bifrost`,
   `model: vllm/Qwen3.8-MXFP4`, and the `mcp-gateway` row with
   `url: http://petunia.home.lan:8080/mcp`.

## Not covered (be honest about this)

- **No live prompt** was sent through dsh → Bifrost, and MCP tools were not
  listed through dsh. Reaching Bifrost was checked separately with curl only
  (`/v1/models` 200, chat completion works, vLLM params pass through).
  The dsh chat path needs the WebSocket RPC or a browser.
- `nix flake check` was run on the Bifrost changes, and the full system builds
  with rc.3; the guest was not booted as a microVM.
- Release notes for 0.1.5-rc.3 specifically were not found (GitHub releases skip
  it); the change from rc.2 was not diffed.

## Ways to lift the ceiling (all untested)

1. **Official Node binary** for dsh only (nodejs.org tarball via `fetchurl` +
   `autoPatchelfHook`, or `nix-ld`), then re-run the validation above. Most
   likely to work if the addon targets official builds.
2. **Rebuild nixpkgs Node** with flags closer to upstream's release build
   (compiler/LTO/PGO differences) — needs the addon's matching logic to
   understand which difference matters.
3. **Patch or replace the addon** — e.g. stub `requireBuiltin` if the
   interception is optional. Risky: dsh uses it to route plugin resolution.
4. **Upstream**: ask `deepseek-ai/deepseek-harness` to support distro Node
   builds or add a fallback; or wait for a newer addon (`0.1.7`+).

What to gain by lifting it (from release notes; 0.1.5-rc.3 → 0.2.0-rc.1): plugin
manager, terminals sidebar, archived-session management, headless `--json`,
`--dump-config-schema`, MCP on SDK v2, Session log V4. Config-affecting changes to
re-check when bumping: settings now saved in the Profile's plugin config with a
one-time import of `settings.yaml`; official DeepSeek adapter Messages-only (we
use `llm-pi-ai`, unaffected); scheduling/time-context/Inspector/automation now
opt-in plugins.

## Related

- Endpoint: inference and MCP both go through Bifrost
  (`http://petunia.home.lan:8080`), models in `modules/_lib/models.nix`.
- `modules/harness/dsh.nix` renders `settings.yaml` and `cordis.patch.yml`
  (copied into the guest, not symlinked).
