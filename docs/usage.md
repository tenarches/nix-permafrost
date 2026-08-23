# Using Project Permafrost Sandboxes

Permafrost is designed for high-capability, declarative agent execution. Because we enforce a strict KVM boundary using `cloud-hypervisor` and rely on high-performance `virtiofs` and `tap` networking, executing a sandbox requires root privileges to configure the host-side network interfaces.

## Agent Inventory

Agents are defined declaratively in `modules/inventory.nix`. Each spec declares its network identity, CLI tools, MCP servers, and persistent filesystem mapping.

| Agent | Purpose | Primary Tool | Key Features |
| :--- | :--- | :--- | :--- |
| **`bv`** | **Builder-Verifier Harness** | Node.js Orchestrator | Dual-agent workflow, MCP bridge, automated verification loop. |
| **`pi`** | Minimal Agentic CLI | `pi` | Optimized for Gemini; minimal baseline for standalone tasks. |
| **`claude`** | Anthropic Specialist | `claude-code` | Native Claude integration; `openclaude` compatibility. |
| **`gemini`** | Google Specialist | `gemini-cli` | Standard interactive Gemini access. |
| **`opencode`** | OpenAI Specialist | `opencode` | Interactive access to OpenAI models. |
| **`antigravity`** | Web Browsing / GUI | Browser / GUI | Specialized for UI interaction. (Wayland passthrough is on every agent — see GUI and Display.) |
| **`crush`** | Local/Remote Sandbox | `crush` | Optimized for resource-heavy batch processing. |

## Launching an Agent

**Local Checkout:**
```bash
sudo nix run .#<agent-name>
```

**Remote JIT:**
```bash
sudo nix run github:tenarches/nix-permafrost#<agent-name>
```

**Terminating the sandbox:** Press `Ctrl-a` then `x`.

## Filesystem and Persistence

Permafrost uses a hybrid filesystem model to balance security and usability.

### 1. Home Files (Declarative)
Files defined in the `homeFiles` attribute of a spec (found in `modules/inventory.nix`) are managed by Home-Manager. These are symlinked from the read-only Nix store into your guest home directory at launch.
- **Example:** The `bv` orchestrator source is symlinked to `~/bv/orchestrator/`.
- **Note:** These files are **read-only**. To modify them, you must update the files in `home-files/` on the host and restart the VM.

### 2. Persistent Shares (Mutable)
Directories declared in `persistentShares` map host paths into the guest. These survive VM termination.
- **`~/.agents`**: Shared state (memories, persistent context).
- **`~/bv`** (in `bv` VM): Houses session logs and mutable orchestrator state.

### 3. Ephemeral Storage (Destroyed on Restart)

Everything else the agent writes lands on per-VM disk images that are **wiped and recreated
on every VM start**. Nothing here survives a restart, and nothing is shared between VMs.

- **`~/workspace`**: A private 50 GiB working directory, backed by a btrfs volume with zstd
  compression. It is **not** a share of the host's `~/workspace` — each VM gets its own.
- **`/tmp`**: A 16 GiB volume. Nix builds lean on `TMPDIR` heavily, so it is kept off both
  the root filesystem and the home volume.
- **`/nix/.rw-store`**: A 50 GiB volume holding the writable overlay above the host's
  read-only Nix store.
- **swap**: 8 GiB, re-initialised each boot.

> **If you need something to survive a restart, put it in `~/.agents` or add a
> `persistentShares` entry in `modules/inventory.nix`.** Work left in `~/workspace` is lost.

Images are sparse, so a booted VM occupies well under 1 MiB of host disk and grows only as
you write.

## Builder-Verifier (BV) Workflow

The `bv` agent is the project's flagship "Agentic Harness." It implements an autonomous dual-agent architecture (Gemini Builder + Qwen Verifier).

### Prerequisites

The BV system requires two external services:

1. **Google Gemini API access** — the Builder uses Gemini 2.5 Pro. You need a Google AI subscription with API access.
2. **Local llama.cpp server** — the Verifier uses Qwen 3.6 35B-A3B served via llama.cpp on the host (or another machine on your network).

### Verifier Model Setup

The Verifier agent runs Qwen 3.6 35B-A3B via a local llama.cpp server. This must be running and reachable from inside the BV guest VM before you start any verification.

**1. Download the model:**

Download a GGUF quantization of Qwen 3.6 35B-A3B (e.g., Q4_K_M or Q5_K_M) from Hugging Face.

**2. Start llama-server:**
```bash
llama-server \
  --model path/to/qwen3.6-35b-a3b.gguf \
  --host 0.0.0.0 \
  --port 8001 \
  --ctx-size 65536 \
  --n-gpu-layers 99
```

For 128k context (large sessions), start a second instance or reconfigure with `--ctx-size 131072`.

**3. Configure the endpoint:**

The verifier endpoint is hardcoded to `http://petunia.home.lan:8001/v1` in three places. If your llama.cpp server runs on a different host or port, update all three:

| File | Field |
|---|---|
| `modules/inventory.nix:152` | `LLAMA_CPP_ENDPOINT` env var |
| `home-files/bv/bv/verifier/extensions/verifier-provider.ts:6` | `baseUrl` |
| `home-files/shared/.pi/agent/models.json:5,29` | `baseUrl` (both providers) |

After changing these files, rebuild the VM (`sudo nix run .#bv`).

**4. Verify connectivity from inside the guest:**
```bash
curl http://your-host:8001/v1/models
```
You should see a JSON response listing the loaded model.

### Initial Setup
Inside the `bv` VM, you must perform a one-time setup for the orchestrator dependencies and authentication:
1.  **Install dependencies:**
    ```bash
    cd ~/.bv-logic/orchestrator
    npm install
    ```
2.  **Authenticate with Google (Gemini):**
    ```bash
    pi /login
    ```
    *Follow the OAuth flow to link your Google subscription. This token is shared between the Builder and Verifier.*

### Setting the Project Root

By default, both agents start in `~/workspace`. To target a specific project, set
`BV_PROJECT_ROOT` before initializing:

```bash
export BV_PROJECT_ROOT=~/workspace/my-project
```

This affects the builder's and verifier's working directory in both interactive and headless modes. If unset, it defaults to `~/workspace`.

> **`~/workspace` is ephemeral.** It is a private per-VM volume wiped on every VM start, so
> a BV run left there does not survive a restart. For durable work, clone into `~/bv` — a
> `persistentShare` — and point `BV_PROJECT_ROOT` at it:
>
> ```bash
> export BV_PROJECT_ROOT=~/bv/my-project
> ```

### Mode 1: Interactive (TMUX)
Best for watching the agents work or debugging prompts. This mode requires a specific 4-pane tmux layout which can be initialized automatically.

1.  **Initialize Layout:**
    ```bash
    cd ~/.bv-logic/orchestrator
    ./init-bv.sh
    ```
    This creates a tmux session named `bv` with the following layout:
    - **Top-Left (0.0):** Builder Agent (`pi`)
    - **Top-Right (0.1):** Verifier Agent (`pi`)
    - **Bottom-Left (0.2):** Coordinator Script
    - **Bottom-Right (0.3):** Live Session Log Watcher

2.  **Attach to Session:**
    ```bash
    tmux attach -t bv
    ```

3.  **Run a Task:**
    In the **bottom-left pane (0.2)**, run:
    ```bash
    ./coordinator.sh path/to/task.md
    ```
    The coordinator drives a full build-verify-feedback loop:
    1. Sends the task to the Builder (top-left) with the `prime` skill.
    2. Waits for the Builder to finish (session JSONL file size stabilizes).
    3. Copies the session log into the Verifier pane (top-right) via tmux paste.
    4. Waits for the Verifier to finish, then extracts its JSON report.
    5. If **PASSED** — exits successfully.
    6. If **FAILED** — extracts the `feedback_for_builder` field and sends it back to the Builder for a retry (up to 2 retries, 3 total attempts).
    7. If retries exhausted — exits with failure and prints the final report.

    Progress is visible in all four panes. The session log watcher (bottom-right) shows the JSONL stream in real time.

### Mode 2: Headless (Orchestrator)
Best for automated implementation and verification.
```bash
cd ~/.bv-logic/orchestrator
npm start -- --task "Implement a JWT authentication service"
```

The orchestrator executes a five-stage loop:
1.  **Prime:** Loads codebase context via the `prime` skill.
2.  **Build:** Builder implements the code and provides verifiable atomic claims.
3.  **Lint:** Runs `tsc` and `eslint` automatically.
4.  **Verify:** Verifier audits the session log against the claims.
5.  **Feedback:** Automatically retries up to 2 times on failure.

### Notification Bus (Optional)

The headless orchestrator emits structured lifecycle events (build started, verify passed, etc.) via a webhook. Configure it by editing `home-files/bv/bv/notify.json`:

```json
{
  "webhookUrl": "http://your-webhook-endpoint",
  "commandListenerEnabled": true,
  "commandListenerPort": 9876
}
```

- **`webhookUrl`**: Where to POST event payloads. Leave as the placeholder value to disable webhook delivery — events still log to stderr.
- **`commandListenerEnabled`**: Starts an HTTP server on port 9876 inside the guest, accepting `abort`, `pause`, `continue`, `inject`, and `status` commands as JSON POST requests.

The notification bus is not required for either mode to function.

### Troubleshooting

**Verifier always returns FAILED/UNCERTAIN:**
- Check that the llama.cpp server is running and reachable from inside the guest (`curl http://your-host:8001/v1/models`).
- Verify the `api` field in `verifier-provider.ts` is `"openai"` (not `"openai-completions"`).
- Check stderr output for `[VERIFY]` lines — if no text_delta events appear, the model endpoint is not responding.

**Coordinator hangs at "Waiting for builder...":**
- The Builder must be running in its pane and actively writing to `~/bv/sessions/`. Check that the Builder pane (top-left) shows an active Pi session.
- If no `.jsonl` files exist in `~/bv/sessions/`, the Builder hasn't started processing yet.

**"tmux session 'bv' already exists":**
- Run `tmux kill-session -t bv` to clean up a stale session, then re-run `./init-bv.sh`.

**Large sessions cause verifier errors:**
- The orchestrator automatically truncates sessions that exceed the model's context window (240k chars for 64k model, 496k for 128k). If truncation drops critical entries, consider using the 128k model by ensuring your llama.cpp server supports 128k context length.

**Coordinator can't extract JSON report:**
- The Verifier is instructed to output compact JSON. If it produces multi-line JSON, the coordinator's grep-based extraction may fail. Check the Verifier pane output directly.

## External Tools (MCP)

The `bv` and `pi` agents have access to the **Model Context Protocol (MCP)** via the `mcporter` bridge.
- **Discover tools:** `npx mcporter list`
- **Call a tool:** `npx mcporter call <server>.<tool> key:value`
- **Config:** Managed declaratively in `~/.mcporter/mcporter.json`.

## SSH Access

Every guest runs `sshd` and is reachable from the host on its inventory IP:

| Agent | Address |
| :--- | :--- |
| `claude` | `agent@192.168.33.10` |
| `antigravity` | `agent@192.168.33.12` |
| `opencode` | `agent@192.168.33.13` |
| `pi` | `agent@192.168.33.14` |
| `crush` | `agent@192.168.33.15` |
| `bv` | `agent@192.168.33.16` |

### Getting a key into the guest

Guests accept keys only — `PasswordAuthentication` is off — and authorized keys are collected **at launch time**, not baked into the image. The runner writes them to a host directory that is virtiofs-mounted at `/etc/ssh/authorized_keys.d/` in the guest, for both `agent` and `root`. Two sources, and they combine:

1. **Your SSH agent.** The runner shells out to `ssh-add -L`, so launch with `sudo -E` to keep `SSH_AUTH_SOCK`:
   ```bash
   sudo -E nix run .#claude
   ```
   If you forget `-E`, the runner probes `/run/user/$(id -u $SUDO_USER)` for an agent socket and prints what it found — but `-E` is the reliable path.

   **Which agent you launch from decides who can log in.** Hosts running TPM-sealed keys keep two separate agents: the personal one at `ssh-tpm-agent.sock`, and a permafrost one at `permafrost-agent.sock` holding only the agentic key. Launch from a session on the **personal** agent — that is the key you interactively log in with. The probe above only ever selects the personal agent, and the runner warns if `SSH_AUTH_SOCK` was inherited pointing at the permafrost one, because that enrols the agentic key instead and your login will be rejected.
2. **`AGENT_PUBKEYS`.** Any keys in that environment variable are appended, one per line. Use this when there is no agent to read:
   ```bash
   sudo AGENT_PUBKEYS="$(cat ~/.ssh/id_ed25519.pub)" nix run .#claude
   ```

### Host-side client config

The host needs a matching block to reach guests: they take a fixed login user, they present a new host key on every boot, and the agent has to be forwarded in. **You do not have to write it.** Launching any agent writes `~/.ssh/config.d/13-permafrost.conf` from `modules/inventory.nix`, so the config for reaching a guest is created by the act of starting it and cannot drift from the inventory. The runner says so when the file changes, and stays quiet when it does not.

It writes one catch-all block covering the whole `192.168.33.0/24` subnet plus a `permafrost-<name>` alias per agent, so `ssh agent@192.168.33.10` and `ssh permafrost-claude` behave identically. Adding an agent to the inventory changes only the aliases — the catch-all is built from what is structural about permafrost. The forwarded socket path is resolved against the launching user's own runtime directory, so nothing depends on a hardcoded uid or an exported variable.

Two things worth knowing:

- **A file you wrote yourself is never clobbered.** The first launch moves an unmanaged `13-permafrost.conf` aside to `13-permafrost.conf.bak` and says so. If you later hand-edit the managed file and a `.bak` already exists, the runner leaves both alone and warns rather than discarding the edit.
- **The fragment must be included ahead of your global `Host *` block.** ssh keeps the first value it obtains for each keyword, so a global `ForwardAgent no` is correctly overridden only when the `Include` sits above it.

The relaxations are deliberately scoped to the subnet and aliases, so `StrictHostKeyChecking no` and `UserKnownHostsFile /dev/null` never apply to anything else you ssh to.

To see what would be written without launching anything, `nix run .#ssh-config`.

(That is the client config for reaching guests. The agent user's own outbound SSH config *inside* the guest is separate — see `modules/programs/ssh.nix`.)

### The forwarded agent, and what a guest may reach with it

A guest holds no private key of its own. Outbound SSH — `git push`, Gitea — works off the agent socket forwarded in over your login, and on a TPM host that socket is `permafrost-agent.sock`, which carries the agentic key and nothing else. The isolation contract is that a guest never sees the personal key. Check it from the host:

```bash
ssh agent@192.168.33.10 ssh-add -l
```

Exactly one key, the agentic one. If the personal key appears, the forwarding is scoped wrong on the **host** side — fix that before trusting the sandbox, because a guest that can use your personal key can use it against anything that key opens.

If no key appears at all, the forwarding block did not match the address you connected to. `ssh -G <address>` settles it: the `forwardagent` line prints the resolved socket path, and the whole check runs without connecting or touching any key file.

> **Do not add `IdentitiesOnly yes`** to `modules/programs/ssh.nix` or to a drop-in without also setting `IdentityFile` to the **public** key. With no `IdentityFile`, `IdentitiesOnly` suppresses agent identities outright — the agent is offered nothing, and a working setup looks convincingly broken.

## GUI and Display

**Every agent can put a window on your host compositor**, through waypipe — no per-spec flag, no virtio-gpu, no special hypervisor. That is the supported path, described in §1 below. Only a Wayland compositor is needed, and only on the host.

A second path exists behind `gui = true` in `modules/inventory.nix`, **off by default**. It gives the guest `microvm.graphics.enable`: a host-side `crosvm device gpu` bridged to your compositor, plus `wayland-proxy-virtwl` as a systemd user service in the guest. It buys "ssh in first, then launch anything" and Xwayland for X11 clients — but it is upstream-fragile, needing three separate version pins to work at all (see §2). Turn it on per-spec if you want it.

The toolkit environment — `NIXOS_OZONE_WL=1`, `LIBGL_ALWAYS_SOFTWARE=1`, `QT_QPA_PLATFORM`, `GDK_BACKEND`, `XDG_SESSION_TYPE` — is set on **every** guest in `modules/agent-base.nix`, independent of `gui`, because both paths need it. Without `NIXOS_OZONE_WL` an Electron build picks its X11 backend and dies on `Missing X server or $DISPLAY`. `WAYLAND_DISPLAY` is deliberately *not* set globally: waypipe exports its own for the process it launches.

### 1. waypipe over SSH — the default path

`waypipe` is installed on the host (`modules/host.nix`) and on every guest (`modules/agent-base.nix`), independent of `gui`. It needs no virtio-gpu, no compositor in the guest, and no special hypervisor — only the binary on both ends, plus sshd:

```bash
waypipe --no-gpu ssh agent@192.168.33.10 <app>
```

`--no-gpu` hides the `wayland-drm` and `linux-dmabuf` globals from the guest. Guests have no render node, so any client that negotiates dmabuf buffers has nowhere to allocate them; blocking the globals pushes it onto `wl_shm`, which is waypipe's primary transport and the only one that can work here.

The catch is that the app must be launched *through* waypipe from the host; sshing in first and running it there will not work, because waypipe's guest-side socket only exists for processes it started. To get the "log in and run several things" workflow anyway, start a shell through it — everything launched inside that shell inherits the right `WAYLAND_DISPLAY`:

```bash
waypipe --no-gpu ssh -t agent@192.168.33.10 bash -l
```

**The `-t` is required for a shell.** waypipe hands ssh a *command*, and ssh only allocates a pty when there is none — so without `-t` the shell starts with its stdin on a pipe, prints no prompt, and looks hung. Options before the destination are passed through to ssh verbatim. Launching an app directly needs no `-t`, since nothing wants a terminal.

Inside that shell, `echo $WAYLAND_DISPLAY` should print something like `wayland-XXXXXXXX` — a one-second check that the tunnel is live.

If the two ends disagree on version, pin both to one binary. The guest mounts the host's `/nix/store`, so any host store path also resolves inside the guest:

```bash
W=$(readlink -f "$(command -v waypipe)")
"$W" --remote-bin "$W" --no-gpu ssh -t agent@192.168.33.10 bash -l
```

That same trick reaches a guest whose configuration predates `waypipe` being installed.

Upstream's `run-waypipe` wrapper (vsock, `-s 2:6000`) is *not* usable as-is here: cloud-hypervisor multiplexes guest vsock ports onto `<socket>_<port>` UNIX sockets on the host, so a host-side `waypipe --vsock` client cannot bind `AF_VSOCK` directly. Use the SSH transport above.

Rendering is Mesa software rasterisation (llvmpipe) — enough for browser automation, headless Chromium, and Electron-based tools. No hardware GPU is exposed to guests.

#### Electron and Chromium apps need GPU flags

Guests have no `/dev/dri`, and Chromium's Ozone/Wayland backend does not fall back gracefully. It looks up a DRM *render node* to build a GBM device and initialises EGL on that, so with no node the GPU process dies and viz restarts it in a loop:

```
drmGetDevices2() has not found any devices: No such file or directory (2)
ANGLE Display::initialize error 12289: Failed to get system egl display
Initialization of all (2) EGL display types failed
Exiting GPU process due to errors during initialization
```

**No window is ever presented.** `LIBGL_ALWAYS_SOFTWARE=1` does not help: the failure happens before Mesa is consulted, because Chromium never asks it for a surfaceless display. Pass the flags to the app instead:

```bash
<electron-app> --ozone-platform=wayland --disable-gpu --disable-gpu-compositing --in-process-gpu
```

- `--disable-gpu` — the one that matters. Chromium stops attempting EGL and composites on the CPU, where Skia's own raster backend is *faster* than SwiftShader anyway.
- `--disable-gpu-compositing` — belt and braces; forces viz to the software output device, which emits `wl_shm` buffers, exactly what waypipe carries best.
- `--in-process-gpu` — optional, removes the separate GPU process so there is nothing left to crash-loop.
- `--ozone-platform=wayland` **explicitly**, not just the hint: Electron's zygote-forked GPU child does not inherit `--ozone-platform` from the browser process (electron/electron#50455, #50462).

Two traps:

- **Never pass `--disable-software-rasterizer`.** It removes the last remaining renderer and converts a slow window into a blank one.
- `--use-gl=swiftshader` is a removed spelling. If the app genuinely needs WebGL, it is `--use-gl=angle --use-angle=swiftshader --enable-unsafe-swiftshader` — slower than plain `--disable-gpu`, so only reach for it when WebGL is required.

These cannot be set globally from the guest configuration: Chromium reads no generic "extra flags" environment variable, and `NIXOS_OZONE_WL` is a nixpkgs *wrapper* convention rather than something Chromium itself honours. They have to reach the app's argv.

#### Running downloaded binaries

`programs.nix-ld` is enabled on every guest (`modules/agent-base.nix`). Agents frequently fetch prebuilt binaries — toolchains, LSP servers, application "hosts" downloaded at first run — and those are foreign ELFs asking for `/lib64/ld-linux-x86-64.so.2`, which NixOS does not otherwise provide. Without nix-ld they fail at exec with a bare `No such file or directory` that names the binary rather than the missing interpreter. If such a binary still fails on a missing `.so`, add the library to `programs.nix-ld.libraries`.

### 2. The in-guest proxy — opt in with `gui = true`

Setting `gui = true` on a spec additionally enables `microvm.graphics`. On the host, microvm.nix starts a `crosvm device gpu` bridged to the invoking session's compositor; in the guest, `wayland-proxy-virtwl` runs as a systemd **user** service serving `/run/user/1000/wayland-1`. Because it is a user service, any session opened later can reach it:

```bash
sudo -E nix run .#claude      # -E: the runner needs XDG_RUNTIME_DIR and WAYLAND_DISPLAY
ssh agent@192.168.33.10
<electron-app>                # WAYLAND_DISPLAY=wayland-1 is already set
```

X11 clients work too: the proxy runs `--x-display=0`, so `DISPLAY=:0` reaches an Xwayland server *inside the guest*. Nothing needs X11 on the host, and sshd needs no `X11Forwarding`.

The runner preflights for a compositor and exits with an explanation if there is none — without that check, microvm.nix's preStart backgrounds `crosvm device gpu` and then spins in `while ! [ -S gpu.sock ]`, which never terminates when crosvm has nothing to attach to. The declarative `microvm.vms` path cannot serve GUI guests at all, since `microvm@<name>.service` is a system unit with no session compositor.

**Why this is off by default.** It rests on three version pins that upstream does not currently hold together:

1. `cloud-hypervisor-graphics` comes from Spectrum's virtio-gpu patches, which apply only to cloud-hypervisor 51.0, while nixpkgs ships 53.0 (`overlays/cloud-hypervisor-graphics.nix`). Enabling `gui` therefore builds cloud-hypervisor from source.
2. That fork requests `GET_SHARED_MEMORY_REGIONS` (message 1004, protocol bit `0x8000_0000`), which crosvm has since replaced with the standardized `SHMEM_MAP`. Hence the `nixpkgs-crosvm` pin in `flake.nix`; without it a guest dies at boot with `VhostUserGetSharedMemoryRegions(Disconnected)`.
3. That older crosvm links against glibc 2.40 while the host's Mesa needs `GLIBC_ABI_GNU2_TLS`, so its Mesa loader is redirected to its own generation (`crosvmGraphics` in `runners.nix`). Without that, rutabaga falls back to a 2D backend and the guest reports `invalid capset id 4294967295` — no cross-domain context, so the proxy cannot work.

Extra variables inside a `gui = true` guest (`modules/graphics.nix`): `WAYLAND_DISPLAY=wayland-1` and `DISPLAY=:0`. Diagnostics when nothing appears:

```bash
# host, while the VM runs
pgrep -af 'crosvm device gpu'
ss -lx | grep gpu.sock

# guest
systemctl --user status wayland-proxy
ls -l /run/user/1000/wayland-1
```

### Choosing between them

| | waypipe (default) | `gui = true` proxy |
| :--- | :--- | :--- |
| Launch an app after logging in | Only inside a shell started by waypipe | Yes |
| Extra build cost | None | cloud-hypervisor 51.0 from source |
| Version pins required | None | Three (see above) |
| Needs a compositor in the launching session | At `waypipe ssh` time | At VM launch |
| X11 clients in the guest | No | Yes, `DISPLAY=:0` |
