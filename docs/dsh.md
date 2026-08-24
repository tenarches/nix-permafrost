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

## 2. The one thing to understand first: nothing persists

The `permafrost` guest is rebuilt from scratch on each boot. Its entire home
directory is a fresh disk image; when the VM stops, it is deleted.

**Anything you create inside the VM is gone when it stops.** That includes your session
history, anything you `git clone`, and any edit you make to dsh's own configuration.

This is deliberate — it is what makes it safe to run an agent with no sandbox — but it
means the workflow is *push your work out before you stop the VM*. `git push` to a real
remote, or copy it out over ssh.

Two exceptions, both host directories mounted into the guest:

- `~/.agents` — shared into the guest, and it is **the host's real `~/.agents`**.
  Writes here land on your actual machine.
- `~/workspace` — despite the name, this is *not* shared. It is a private, ephemeral
  directory on the guest's own disk.

Unlike the other harnesses in this guest, `dsh` maps no host directories of its own. Its whole
configuration is generated from Nix and copied in fresh on every boot.

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

There is no terminal UI, so anything interactive happens in a browser. Two helpers ship
in the guest.

**`dsh-web`** — the default. Serves on the guest's loopback only. From your host:

```bash
ssh -L 3080:127.0.0.1:3080 permafrost    # leave this running
# then in that session, or another one:
dsh-web
```

Open <http://localhost:3080>.

**`dsh-web-lan`** — skips the tunnel. Serves on all the guest's interfaces:

```bash
ssh permafrost
dsh-web-lan
```

Open <http://192.168.33.10:3080> directly from the host.

Neither opens a browser — there isn't one in the guest.

> **Why two.** Upstream deliberately refuses `--host 0.0.0.0`, on the grounds that it
> "would expose remote code execution to the network", and the bind address is a closed
> choice of `127.0.0.1` or `0.0.0.0` — you cannot name a specific IP. `dsh-web-lan` sets
> the bind through the config layer, which has no such guard.
>
> That is a considered exception, not an oversight. `192.168.33.0/24` is a bridge that
> exists only on your host and is NAT'd outbound, so "all interfaces" here means the host
> and anything else that ever joins that bridge — not the internet. It is still a real
> widening: this UI drives an agent with its sandbox off, and anything with LAN access to
> the guest can reach it. Loopback stays the default for that reason.
>
> Requests are additionally fenced on their `Host` header — a request arriving with a
> forged `Host` gets `403 forbidden` regardless.

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
runtime, reset on every boot.

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
├── sessions/              conversation logs, zstd-compressed JSONL
└── storages/              web UI state
```

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
| `modules/harness/dsh.nix` | Everything dsh-specific: generated config, the three helpers, the firewall port |
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

**403 from the web UI.** The Host-header fence. Reach the UI at the address it was bound
to, not through a proxy or alias.

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
