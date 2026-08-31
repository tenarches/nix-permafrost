# The `dsh` agent — DeepSeek Harness on local inference

A guide for someone who has not used this repository before. It assumes you know
Linux and git, and nothing about permafrost, microvms, or dsh.

Everything below was checked against dsh `0.1.1-rc.2` and the built guest. Where a
claim could not be checked, it says so.

---

## 1. What you are getting

`dsh` is one of several **harnesses** carried by the one disposable guest this repo boots —
see the [README](../README.md) if you have not met `permafrost` yet. This harness runs the [DeepSeek
Harness](https://github.com/deepseek-ai/deepseek-harness), pointed at the **local vLLM
server at `petunia.home.lan:8000`** — no external API, no key, nothing leaves the network.

What is set up for you:

| | |
|---|---|
| Model | `qwen3.8-27b`, 128k context, text + images |
| Reasoning | **medium** by default (the models' own default is `xhigh`) |
| MCP servers | context7, time, nixos, terraform — running, no setup |
| Skills | seven curated skills, pre-installed and editable |
| Browser | `playwright` on `PATH`, chromium/firefox/webkit already built |
| Sandbox | **off** — see [§8](#8-the-permission-posture) before you get comfortable |

---

## 2. The one thing to understand first: the guest is disposable

The `permafrost` guest is rebuilt from scratch on each boot. Its entire home
directory is a fresh disk image; when the VM stops, it is deleted.

**Assume anything you create inside the VM is gone when it stops.** That includes anything
you `git clone` and any edit you make to dsh's own configuration. This is deliberate — it
is what makes it safe to run an agent with no sandbox — so the workflow is *push your work
out before you stop the VM*. `git push` to a real remote, or copy it out over ssh.

A short list of paths is exempt, because they are host directories mounted into the guest
over virtiofs. Writes to these land on your actual machine:

| Path in the guest | What it is |
|---|---|
| `~/.agents` | The host's real `~/.agents` — skills and instructions every harness reads |
| `~/.dsh/sessions` | Your conversation history |
| `~/.dsh/attachments` | The blobs those sessions reference |
| `~/.dsh/storages` | The web UI's own state — workspace list, session cache |

The three under `~/.dsh` are there so a long-horizon task can be picked up again after a
shutdown. Everything *else* under `~/.dsh` is deliberately not shared and comes back
Nix-fresh on every boot — `settings.yaml`, `cordis.patch.yml`, `skills/` and `profiles/`.
[§6](#6-how-dsh-is-configured) has the full tree and the reasoning.

Two paths that look like they should be on that list and are not:

- `~/workspace` — despite the name, this is **not** a share of the host's. It is a private,
  ephemeral directory on the guest's own disk, and it is wiped with everything else.
- `~/.dsh/profiles` — regenerated on every launch, and mostly a farm of symlinks into the
  guest's own Nix store, which would mean nothing on the host.

---

## 3. Launching it

From a checkout of this repo, on the host:

```bash
sudo nix run .#permafrost
```

Root is needed to create the guest's network interface, not by dsh. This boots the whole
`permafrost` guest — every harness, dsh included — there is no `dsh`-only runner.

That command builds the VM if needed, boots it, and attaches your terminal to its
console. **To shut it down, press `Ctrl-a` then `x`.**

To run it in the background instead:

```bash
sudo nix run .#permafrost start   # boot detached
nix run .#status                   # is the guest up, and at what address
sudo nix run .#permafrost stop
```

The guest is `192.168.33.10`. Launching also writes an ssh config entry for you, so:

```bash
ssh permafrost
```

That is the normal way in — the console works, but a real ssh session gives you a proper
terminal and agent forwarding. Your ssh agent is forwarded, so `git clone` from your
private forges works inside the guest without copying any key in.

---

## 4. Actually talking to it — there is no TUI

This is the biggest surprise coming from other agent CLIs. `dsh` is a *profile launcher*,
not a chat program. Typing `dsh` alone gets you a help page. There are two ways to use it.

### One-shot, from the shell

```bash
dsh --profile headless "list the files in ~ and tell me what this project is"
```

It runs the task, prints the final answer to stdout, and exits — 0 if it completed,
non-zero otherwise. No server, no port, nothing to clean up. Good for scripting.

### The browser UI

There is no terminal UI, so anything interactive happens in a browser. You start a server
in the guest, then reach it from the host.

#### Starting it

The server does not autostart — a guest boots with no web UI listening. Start it by hand:

```bash
ssh permafrost
systemctl --user start dsh-web     # returns immediately; runs until stopped
```

and to watch it, or stop it:

```bash
journalctl --user -u dsh-web -f
systemctl --user stop dsh-web
```

The same command is also on `PATH` as `dsh-web`, if you would rather have the output in
front of you than in the journal. It runs in the foreground; `Ctrl-C` stops it. Only one of
the two can hold port 3080, so the second one you start exits with an address-in-use error.

> `systemctl --user enable dsh-web` is not the missing step — it prints an explanation and
> does nothing. The unit has no `[Install]` section on purpose, because enabling *is*
> linking into a target, which is exactly the autostart being avoided. Start it per boot.

Two footnotes on the foreground form. `Ctrl-C` reaches dsh's MCP child processes as well as
dsh, and one of them — `mcp-server-time` — has no `KeyboardInterrupt` guard, so it prints a
long Python traceback on the way out. It is noise, not a failure. The service does not do
this: `systemctl stop` sends `SIGTERM`, which Python takes without an exception.

#### Reaching it

**Over TLS, no tunnel.** Open <https://192.168.33.10:3443> from the host. The guest runs
caddy in front of the server; whether your browser says anything depends on where the
certificate came from, which is [below](#where-the-certificate-comes-from).

**Over an ssh tunnel.** From the host:

```bash
ssh -L 3080:127.0.0.1:3080 permafrost    # leave this running
```

Open <http://localhost:3080>. No certificate prompt, because `localhost` gets the same
treatment `https` does.

> **The UI does not work over plain `http` to `192.168.33.10`.** Every request the page
> makes mints an id with `crypto.randomUUID()`, which browsers define only in a *secure
> context* — `https`, or `http` on `localhost`. A plain-http origin on a private address
> is neither, so the first API call dies with
>
> ```
> Loading the provider directory failed: crypto.randomUUID is not a function
> ```
>
> and Agent preset, Models and everything behind them stay empty. That is the whole reason
> for the TLS front end; there is no dsh setting that avoids it.

#### Where the certificate comes from

Nothing needs configuring to pick between the two paths. `nix run .#permafrost` tries
Vault, says which way it went, and carries on either way; a launch never fails because
Vault was unreachable or your token had expired.

**If you were logged into Vault when you launched**, the launcher called
`pki_int_homelab/issue/permafrost-guest` as you, before the guest started, and passed the
result in over a one-shot share destroyed with the VM. That chain is already in your host's
trust store, so the page opens with no prompt at all. The guest never talks to Vault and
holds no Vault credential — it receives one leaf, for one address, and that is all it could
ever leak. Override `VAULT_ADDR`, `VAULT_PKI_MOUNT`, `VAULT_PKI_ROLE`, `VAULT_TLS_CN` or
`VAULT_TLS_TTL` in the environment if your CA is arranged differently; `sudo -E` or
`~/.vault-token` both work for the token. The launch line reports the validity Vault
actually granted rather than what was asked for, because a `ttl` beyond the role's
`max_ttl` is capped rather than refused — and repeats any warning Vault returns, which is
where that capping shows up.

**Otherwise the guest self-signs**, and you get the usual interstitial on every launch,
because the guest and its certificate are both rebuilt each boot. Clicking through still
gives you an `https` origin, which is all the page needs. That fallback is a bare
self-signed leaf — no certificate authority anywhere in it, and nothing added to a trust
store on the guest or your host. It is generated by the caddy service's own first act, as
the unprivileged `caddy` user, inside the state directory systemd hands it.

**Neither certificate can be revoked, by design.** The `permafrost-guest` role sets
`no_store=true`, so Vault keeps no copy and there is no serial to revoke against. That is
deliberate on two counts. Revoking at shutdown was never going to work — a task that runs
for days outlives the token that would have to authorise it, and there is no
unauthenticated revocation path (`revoke-with-key` is unprivileged in the sense of not
needing the revoke capability, but it still needs a token). And with storage off, the
mount's unauthenticated `cert/*` path no longer hands out every certificate this guest has
ever been issued. What bounds a leaked key instead: its TTL, a single SAN on a host-local
bridge address, `client_flag=false` so it cannot be presented as a client certificate
anywhere, and a guest in which the agent has no route to root and so cannot read it.

#### What is exposed

`3443` is the only port this harness opens — the guest's firewall allows that and `22`, and
nothing else. dsh's own listener stays on the guest's loopback, so the plaintext UI is not
on the bridge at all. `192.168.33.0/24` is a bridge that exists only on
your host and is NAT'd outbound, so the TLS port is reachable from the host and anything
else that joins that bridge — not from the internet. It is still worth knowing this UI
drives an agent with its sandbox off.

Requests are additionally fenced on their `Host` header. The server is started with
`--trusted-host 192.168.33.10` and `--trusted-host permafrost.home.lan`, so the address
caddy forwards under is accepted; a request arriving with any other `Host` gets
`403 forbidden`.

---

## 5. Switching models

The catalogue lives in **`modules/_lib/models.nix`**, on the host, and is shared with `pi` —
both harnesses read the one source and render it into two config files inside the same
`permafrost` guest. Three models are declared:

```
qwen3.6-27b
qwen3.8-27b        <- the default
qwen3.6-35b-a3b
```

> Declared is not the same as loaded. At the time of writing, the vLLM server was serving
> only `qwen3.8-27b`. Check what is actually up with
> `curl -s http://petunia.home.lan:8000/v1/models | jq -r '.data[].id'`. Selecting a model
> the server is not serving fails at request time, not at startup.

**Inside the guest**, to switch:

```bash
dsh-model                      # list, and show the current default
dsh-model qwen3.6-35b-a3b      # switch
```

Then restart the profile — the default model lives in the composition layer, which is
read at boot. The change lasts until the VM stops.

You can also switch per-session in the web UI's Models page.

**To change it permanently**, or to add a model, edit `modules/_lib/models.nix` on the host
and relaunch. Adding a model is one entry in the `models` list; it reaches `dsh` and `pi`
together.

### Reasoning effort

The models default to `xhigh`, which spends most of a 128k context thinking before
reaching the task. This config sets **`medium`**, and that is what every request uses
unless it asks for something else.

All levels stay available — `off`, `minimal`, `low`, `medium`, `high`, `xhigh` — so you
can ask for more on a specific turn. Nothing escalates on its own.

---

## 6. How dsh is configured

dsh is built on a plugin-injection framework, and configuration comes in **two separate
planes**. Knowing which is which saves a lot of confusion.

| File | What it is | Reloads |
|---|---|---|
| `~/.dsh/settings.yaml` | **User settings.** Model providers, endpoints, credentials-by-name. What the web Models page writes. | Live, on save |
| `~/.dsh/cordis.patch.yml` | **Composition.** Which plugins are mounted and how. MCP servers and the default model. | On profile restart |

Both are generated from `modules/harness/dsh.nix` and **copied** into the guest — not symlinked.
That matters: dsh rewrites files under `~/.dsh` on every boot, and the web UI writes
`settings.yaml` in place, so read-only files there would break it.

The upshot is a nice property: you get a declarative baseline you can freely edit at
runtime, reset on every boot. Your *conversations* are not part of that reset — see the
tree below.

### What lives under `~/.dsh`

Observed after a real run:

```
~/.dsh/
├── settings.yaml          generated — model providers
├── cordis.patch.yml       generated — plugins, MCP servers, default model
├── skills/                generated — the curated skills (§7)
├── profiles/
│   ├── web/               rewritten by dsh on every boot — do not manage this
│   ├── headless/
│   └── node_modules/      symlink farm, healed on every launch
├── attachments/           SHARED — blobs the sessions reference
├── sessions/              SHARED — conversation logs, zstd-compressed JSONL
└── storages/              SHARED — web UI state
```

The three marked `SHARED` are `permafrost.shares` entries: symlinks into `/mnt/persist`,
backed by `~/.dsh/<name>` on the host, and they outlive the guest. Everything else in the
tree is rebuilt on every boot — see [usage.md](usage.md#2-persistent-shares-mutable) for why
the split falls where it does.

To see the fully composed plugin tree, with every layer applied:

```bash
dsh --profile headless --dump-config
```

That is the fastest way to check whether an edit took effect.

### One rule that will bite you

A patch **replaces the targeted row's entire `config`** — it does not merge keys into it.
If you override a plugin row, restate its whole configuration, or you will silently drop
the parts you left out.

---

## 7. Skills

Skills are a directory per skill, each with a `SKILL.md` whose YAML frontmatter carries a
`name` and a `description`. The agent reads the descriptions and pulls in the body when
one looks relevant.

Seven come pre-installed, from a private repo pinned in `flake.nix`:

```
crawl4ai                        nixos-den-architect
devenv2-environment-generator   nomad-ops-skill
hybrid-web-search               tika-analyst
nix-flake-architect
```

They land in `~/.dsh/skills/` and are **writable** — edit one mid-session to try a change.
It reverts on the next boot; to keep it, commit it to the skills repo and re-lock.

**To add a skill for one session**, just make the directory:

```bash
mkdir -p ~/.dsh/skills/my-skill
$EDITOR ~/.dsh/skills/my-skill/SKILL.md
```

Two things will silently drop a skill: a `name` that is not kebab-case, and a nested
layout. Only `<name>/SKILL.md` one level down is scanned — `a/b/SKILL.md` is ignored.
(The skills repo has one such nested file; it is correctly not picked up.)

### You will also see the host's skills

dsh scans several roots. Two matter here:

| Root | Contents |
|---|---|
| `~/.dsh/skills` | the seven above |
| `~/.agents/skills` | **your host's own skills**, via the shared mount from §2 |

So the guest sees the union of both. Where a name appears in both, `~/.dsh/skills` wins —
it is the higher-precedence root. If that surprises you, `~/.agents` is the one host
directory this guest inherits from the fleet-wide default.

---

## 8. The permission posture

**dsh's own sandbox is turned off in this guest, and nothing asks for approval.** The
agent can run any command and edit any file as the `agent` user, without prompting.

`DSH_PERMISSION_MODE=danger-full-access` is set in the spec on purpose: the VM *is* the
boundary. It is disposable, it holds nothing you have not put there, and it maps no host
directories of its own.

Two things that boundary does **not** cover:

- `~/.agents` is your real host directory. The agent can write to it.
- The guest has full network access, including your internal network.

If you want prompts back for a session, launch with `DSH_PERMISSION_MODE=workspace-write`.
Note that dsh's sandbox wants `bwrap` on `PATH` to actually enforce anything, and it is
deliberately not installed here — so that setting will restore the *approval prompts* but
not real confinement.

---

## 9. Adding an MCP server

MCP servers are plugin rows in the composition layer. **None are enabled by default**
upstream — each one is executable code running outside the agent's sandbox, so mounting
one is meant to be deliberate. Four are wired up here.

To add one for a session, edit `~/.dsh/cordis.patch.yml` and add to the `insert` list:

```yaml
- id: mcp-example
  name: '@deepseek-ai/dsh-mcp-client'
  config:
    serverName: example          # [A-Za-z0-9_-]{1,32}, must be unique
    transport: stdio             # or: streamable-http, with `url` instead
    command: /path/to/server
    args: ['stdio']              # only if the server needs a subcommand
```

Restart the profile. Its tools appear as `mcp__example__<toolname>`.

To make it permanent, add it to the `mcpServers` list in `modules/harness/dsh.nix` — that renders
the same row with a store path for `command`, so it does not depend on `PATH`.

**A note on stderr.** An MCP server is a child process and inherits the terminal's stderr,
so anything it logs there lands in your session, interleaved with dsh's own output. That
is where the terraform server's `failed to create TFE client` complaint came from: it
reaches for an HCP Terraform client whether or not one is configured, no token reaches
this guest, and the nine registry tools work regardless. It is silenced with
`--log-level fatal` rather than fixed, because there was nothing broken to fix. Expect the
same from any server you add that is chatty on stderr — and if a server hangs at startup
instead, check stderr first, since that is where it will say why.

**GitHub.** `github-mcp-server` is installed but deliberately not mounted: it exits at
startup unless `GITHUB_PERSONAL_ACCESS_TOKEN` is set, and no token reaches this guest. To
use it, provide a token and add:

```yaml
- id: mcp-github
  name: '@deepseek-ai/dsh-mcp-client'
  config:
    serverName: github
    transport: stdio
    command: github-mcp-server
    args: ['stdio']
    env:
      GITHUB_PERSONAL_ACCESS_TOKEN: !!js process.env.GITHUB_TOKEN
```

`!!js` marks a value evaluated when the config loads — that is how you forward an
environment variable, since a server's environment is otherwise scrubbed of credentials.

Only **tools** are bridged. MCP Resources and Prompts are not wired to anything.

---

## 10. Things that are not here

Verified absent, so you do not go looking:

- **Git worktree isolation for subagents.** Subagents exist (`spawn` and `fork`, in
  process), but nothing creates isolated worktrees — the scripting API rejects an
  `isolation` option outright. The VM is the isolation boundary instead.
- **A TUI.** See §4.
- **Theme and keybinding configuration.** No config surface for either.
- **Project-local config.** MCP servers and settings are per-harness-home or per-profile.
  There is no `.dsh/` discovery in your project directory for these.

Optional subagent providers for Codex and Claude Code exist upstream and can be installed
into a profile with `dsh plugin --profile web add <package>` — that needs `pnpm`, which is
installed, and network access. Not tried here.

---

## 11. Where things live in this repo

| Path | Role |
|---|---|
| `modules/harness/dsh.nix` | Everything dsh-specific: generated config, the three helpers, the `dsh-web` user service, the three data shares, the firewall port |
| `modules/guest/shares.nix` | How a `permafrost.shares` entry becomes a mount and a symlink |
| `modules/_lib/models.nix` | The shared model catalogue — endpoint, models, thinking budgets |
| `modules/guest/identity.nix` | The guest's address, `permafrost.identity.ip = 192.168.33.10` |
| `flake.nix` | The `agent-skills` and `llm-agents` inputs |
| `modules/_pkgs/runner.nix` | `nix run .#permafrost` |

Two notes for anyone editing these:

- `modules/_lib/models.nix` renders **two shapes**, because the consumers disagree. dsh's
  thinking-budget schema accepts only `minimal`/`low`/`medium`/`high` and rejects the
  `xhigh` key that pi accepts. That is what `dshThinkingBudgets` is for.
- The `agent-skills` input is a private repo over ssh, so `nix flake check` needs an ssh
  key that can reach it. Drop the input and the skills copy in `modules/harness/dsh.nix` if you
  are forking this.

---

## 12. Troubleshooting

**The model returns an error on every request.** dsh infers the request shape from the
endpoint URL and treats anything it does not recognise as OpenAI. Two corrections are
already applied (`supportsDeveloperRole: false`, `maxTokensField: max_tokens`). The next
lever is `compat.thinkingFormat` in `settings.yaml` — try `qwen`, then `qwen-chat-template`,
then `deepseek`.

**`UNSUPPORTED_REASONING_EFFORT`.** The requested level is not in that model's
`reasoningEfforts` map in `settings.yaml`.

**Config changes do nothing.** Check which plane you edited — `settings.yaml` reloads
live, `cordis.patch.yml` needs a profile restart. Confirm with `--dump-config`.

**A skill is not showing up.** Kebab-case `name` in the frontmatter, and
`<name>/SKILL.md` exactly one level down.

**403 from the web UI.** The Host-header fence. Reach the UI at
<https://192.168.33.10:3443> or <http://localhost:3080>, not through a proxy or alias of
your own.

**`crypto.randomUUID is not a function`.** You are on a plain-http origin that is not
localhost. Use <https://192.168.33.10:3443> or the tunnel — see [§4](#the-browser-ui).

**502 from <https://192.168.33.10:3443>.** caddy is up but the server is not running in the
guest — expected on a fresh boot, since it does not autostart. `ssh permafrost` and
`systemctl --user start dsh-web`, then `systemctl --user status dsh-web` if it does not
come up.

**`Address already in use` on port 3080.** The service and the foreground `dsh-web` command
are the same server and cannot both hold the port. `systemctl --user status dsh-web` says
whether the service already has it.

**A Python traceback when you `Ctrl-C` the foreground `dsh-web`.** Expected, and harmless:
`Ctrl-C` reaches dsh's MCP children too, and `mcp-server-time` does not guard
`KeyboardInterrupt`. `systemctl --user stop dsh-web` exits silently instead.

**`Permission denied (publickey)` on `git push` from the web UI or a long-lived pane.** The
guest has no key of its own; pushes go through `~/.ssh/agent.sock`, a stable symlink to the
forwarded agent socket (`modules/guest/ssh-agent-socket.nix`). It dangles when the
connection it pointed at closes, and any new `ssh permafrost` re-points it — open one and
retry. If a fresh session also has no key, the forwarding itself is off: check
`ssh agent@192.168.33.10 ssh-add -l` from the host.

**The VM will not start.** `sudo nix run .#permafrost` needs root, a free `192.168.33.10`,
and KVM. `nix run .#status` shows whether the guest is already running; `nix run .#gc`
reclaims disk from a guest directory that is gone.

---

## 13. Upstream is a preview

dsh is version `0.1.1-rc.2` and its README says plainly: *"THERE WILL BE
COMPATIBILITY-BREAKING CHANGES."*

The version is pinned by hash, so this guest is reproducible and will keep working. But a
future `nix flake update` can invalidate any config key described here. If dsh stops
loading its config after an update, that is the first thing to suspect —
`--dump-config` names the row it choked on.
