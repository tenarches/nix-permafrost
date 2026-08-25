# Using Project Permafrost Sandboxes

Permafrost is designed for high-capability, declarative agent execution. Because we enforce a strict KVM boundary using `cloud-hypervisor` and rely on high-performance `virtiofs` and `tap` networking, executing the sandbox requires root privileges to configure the host-side network interfaces.

## Harness Inventory

There is one guest, `permafrost`, carrying every harness at once. Each is one file under
`modules/harness/`, declaring its own packages and its own share of persistent host state
via `permafrost.shares`.

| Harness | Purpose | Primary Tool | Key Features |
| :--- | :--- | :--- | :--- |
| **`claude`** | Anthropic Specialist | `claude-code` | Native Claude integration. Shares `~/.claude` and `~/.claude.json`. |
| **`openclaude`** | Claude Code alternative | `openclaude` | An independent fork, vendored from npm rather than `llm-agents.nix`. Keeps its own state: shares `~/.openclaude` and `~/.openclaude.json`. |
| **`opencode`** | OpenAI Specialist | `opencode` | Interactive access to OpenAI models. Shares `~/.config/opencode`. |
| **`pi`** | Minimal Agentic CLI | `pi` | Optimized for Gemini and the self-hosted models; ships with `mcporter`. Shares `~/.pi` and `~/.mcporter`. |
| **`crush`** | Local/Remote Sandbox | `crush` | Optimized for resource-heavy batch processing. Shares `~/.config/crush` and `~/.local/share/crush`. |
| **`dsh`** | Self-Hosted Inference | `dsh` (DeepSeek Harness) | Local vLLM only; MCP servers, curated skills, browser UI. No TUI, no shares — see [docs/dsh.md](dsh.md). |
| **`antigravity`** | Web Browsing / GUI | `antigravity-cli` | No shares of its own — nothing it produces is worth carrying across a boot. |
| **`mcp`** | Shared MCP servers | context7, time, github, terraform, nixos | Available to any harness that speaks the protocol; a harness still has to be told about a server (see `dsh`'s plugin rows). |
| **`browser`** | Browser automation | `playwright-test` | Chromium/Firefox/WebKit prebuilt via Nix, `PLAYWRIGHT_BROWSERS_PATH` pointed at them. |

Adding an agent is adding one more file in this shape — see the README's
[Harness Modules](../README.md#harness-modules) section for the file itself and how it is
discovered.

## Launching the Guest

**Local Checkout:**
```bash
sudo nix run .#permafrost
# .#default is the same package:
sudo nix run .
```

**Remote JIT:**
```bash
sudo nix run github:tenarches/nix-permafrost#permafrost
```

**Terminating the sandbox:** Press `Ctrl-a` then `x`.

**Running detached, checking status, stopping:**
```bash
sudo nix run .#permafrost start   # boot detached
nix run .#status                   # is it up, and at what address
sudo nix run .#permafrost stop
```

There is one runner rather than one per agent: per-agent names such as `.#claude` or
`.#dsh` are not kept as aliases, since each would boot the same guest under a name that
distinguishes nothing.

## Filesystem and Persistence

Permafrost uses a hybrid filesystem model to balance security and usability.

### 1. Home Files (Declarative)

Some harness state is managed by Home Manager rather than mounted from the host, and is
symlinked from the read-only Nix store into the guest home at boot. `pi`'s model catalogue
is the clearest example: `modules/harness/pi.nix` renders `~/.pi/agent/models.json` from the
shared model list in `modules/_lib/models.nix` as a store symlink — pi only ever reads this
file, never rewrites it, so a symlink is safe.
- **Note:** These files are **read-only**. To change one, edit the Nix module that generates
  it and relaunch. `dsh` is the counter-example: its configuration is also rendered from
  Nix, but *copied* rather than symlinked, because dsh and its web UI rewrite files under
  `~/.dsh` in place — see [docs/dsh.md](dsh.md) for why a store symlink would break it there.

### 2. Persistent Shares (Mutable)

`permafrost.shares` entries map host paths into the guest over virtiofs; they survive VM
termination. Thirteen are declared across the guest-wide and per-harness modules:

| Share | Declared by | Guest path |
| :--- | :--- | :--- |
| `.agents` | `guest/base.nix` (every guest) | `~/.agents` — skills and instructions every harness reads |
| `.claude` | `harness/claude.nix` | `~/.claude` |
| `.config/claude` | `harness/claude.nix` | `~/.claude-config`, linked at `~/.claude.json` |
| `.openclaude` | `harness/openclaude.nix` | `~/.openclaude` |
| `.config/openclaude` | `harness/openclaude.nix` | `~/.openclaude-config`, linked at `~/.openclaude.json` |
| `.config/opencode` | `harness/opencode.nix` | `~/.config/opencode` |
| `.pi` | `harness/pi.nix` | `~/.pi` — Gemini OAuth tokens from `pi /login` |
| `.mcporter` | `harness/pi.nix` | `~/.mcporter` |
| `.config/crush` | `harness/crush.nix` | `~/.config/crush` |
| `.local/share/crush` | `harness/crush.nix` | `~/.local/share/crush` |
| `.dsh/sessions` | `harness/dsh.nix` | `~/.dsh/sessions` — conversation history |
| `.dsh/attachments` | `harness/dsh.nix` | `~/.dsh/attachments` — blobs those sessions reference |
| `.dsh/storages` | `harness/dsh.nix` | `~/.dsh/storages` — web UI state |

**`~/.dsh` is shared three directories deep, not whole**, and the split is deliberate. dsh is
a plugin-DI launcher that rewrites its own composition file on every boot, and its web UI
rewrites `settings.yaml` live — a read-only virtiofs share (or even a store symlink) over
those would break both. So `modules/harness/dsh.nix` renders that half from Nix and an
activation script *copies* it into the ephemeral home fresh on every boot.

Two more things under `~/.dsh` stay ephemeral for reasons of their own. `skills/` is
generated the same way, and the activation script `rm -rf`s it first — on a share that would
delete a host directory. `profiles/` is a symlink farm into the guest's own Nix store, so
persisting it would only accumulate paths that dangle after the next garbage collection.

What *is* shared is the data: sessions, the attachments they reference, and the web UI's
state, so a long-horizon task can be resumed after a shutdown.

### 3. Ephemeral Storage (Destroyed on Restart)

Everything else the agent writes lands on per-VM disk images that are **wiped and recreated
on every VM start**. Nothing here survives a restart.

- **`~/workspace`**: A private 50 GiB working directory, backed by a btrfs volume with zstd
  compression. It is **not** a share of the host's `~/workspace` — the guest gets its own,
  wiped every boot.
- **`/tmp`**: A 16 GiB volume. Nix builds lean on `TMPDIR` heavily, so it is kept off both
  the root filesystem and the home volume.
- **`/nix/.rw-store`**: A 50 GiB volume holding the writable overlay above the host's
  read-only Nix store.
- **swap**: 8 GiB, re-initialised each boot.

> **If you need something to survive a restart, put it in `~/.agents` or add a
> `permafrost.shares` entry to the harness module that needs it.** Work left in
> `~/workspace` — or, for `dsh`, anywhere under `~/.dsh` other than the three shared
> directories above — is lost.

Images are sparse, so a booted VM occupies well under 1 MiB of host disk and grows only as
you write.

## External Tools (MCP)

`modules/harness/mcp.nix` puts context7, time, github, terraform, and nixos MCP servers on
`PATH` for any harness that knows how to speak the protocol. `pi`, alongside `mcporter`, is
the harness set up to actually reach them:
- **Discover tools:** `npx mcporter list`
- **Call a tool:** `npx mcporter call <server>.<tool> key:value`
- **Config:** Managed declaratively in `~/.mcporter/mcporter.json`.

`dsh` reaches the same servers a different way — as plugin rows in its own composition
layer rather than through `mcporter` — since it has no `mcpServers` concept of its own; see
[docs/dsh.md](dsh.md#9-adding-an-mcp-server).

## SSH Access

The guest runs `sshd` and is reachable from the host at `agent@192.168.33.10`.

### Getting a key into the guest

The guest accepts keys only — `PasswordAuthentication` is off — and authorized keys are collected **at launch time**, not baked into the image. The runner writes them to a host directory that is virtiofs-mounted at `/etc/ssh/authorized_keys.d/` in the guest, for both `agent` and `root`. Two sources, and they combine:

1. **Your SSH agent.** The runner shells out to `ssh-add -L`. Plain `sudo` is enough:
   ```bash
   sudo nix run .#permafrost
   ```
   `sudo` clears `SSH_AUTH_SOCK`, so the runner probes `/run/user/$(id -u $SUDO_USER)` for an agent socket and prints which one it found. `sudo -E` preserves the variable instead and skips the probe; both work.

   **Which agent you launch from decides who can log in**, and on a two-agent host the probe is the safer of the two. Hosts running TPM-sealed keys keep the personal agent at `ssh-tpm-agent.sock` and a permafrost one at `permafrost-agent.sock` holding only the agentic key, which is not enrolled for interactive login. The probe matches socket names exactly and only ever selects the personal agent — deliberately never `permafrost-agent.sock`, since a wildcard there would enrol the agentic key for interactive login and for root, inverting the split the two agents exist to provide. `sudo -E` carries in whatever your session happens to hold, so it can hand the runner the permafrost agent and leave your own login rejected; the runner warns when it sees that.
2. **`AGENT_PUBKEYS`.** Any keys in that environment variable are appended, one per line. Use this when there is no agent to read:
   ```bash
   sudo AGENT_PUBKEYS="$(cat ~/.ssh/id_ed25519.pub)" nix run .#permafrost
   ```

### Host-side client config

The host needs a matching block to reach the guest: it takes a fixed login user, it presents a new host key on every boot, and the agent has to be forwarded in. **You do not have to write it.** Launching the guest writes `~/.ssh/config.d/13-permafrost.conf` from `permafrost.identity`, so the config for reaching it is created by the act of starting it and cannot drift. The runner says so when the file changes, and stays quiet when it does not.

It writes one catch-all block covering the whole `192.168.33.0/24` subnet plus a bare `permafrost` alias, so `ssh agent@192.168.33.10` and `ssh permafrost` behave identically. The forwarded socket path is resolved against the launching user's own runtime directory, so nothing depends on a hardcoded uid or an exported variable.

Two things worth knowing:

- **A file you wrote yourself is never clobbered.** The first launch moves an unmanaged `13-permafrost.conf` aside to `13-permafrost.conf.bak` and says so. If you later hand-edit the managed file and a `.bak` already exists, the runner leaves both alone and warns rather than discarding the edit.
- **The fragment must be included ahead of your global `Host *` block.** ssh keeps the first value it obtains for each keyword, so a global `ForwardAgent no` is correctly overridden only when the `Include` sits above it.

The relaxations are deliberately scoped to the subnet and the alias, so `StrictHostKeyChecking no` and `UserKnownHostsFile /dev/null` never apply to anything else you ssh to.

To see what would be written without launching anything, `nix run .#ssh-config`.

(That is the client config for reaching the guest. The agent user's own outbound SSH config *inside* the guest is separate — see `modules/guest/home/ssh.nix`.)

### The forwarded agent, and what the guest may reach with it

The guest holds no private key of its own. Outbound SSH — `git push`, Gitea — works off the agent socket forwarded in over your login, and on a TPM host that socket is `permafrost-agent.sock`, which carries the agentic key and nothing else. The isolation contract is that the guest never sees the personal key. Check it from the host:

```bash
ssh agent@192.168.33.10 ssh-add -l
```

Exactly one key, the agentic one. If the personal key appears, the forwarding is scoped wrong on the **host** side — fix that before trusting the sandbox, because a guest that can use your personal key can use it against anything that key opens.

If no key appears at all, the forwarding block did not match the address you connected to. `ssh -G <address>` settles it: the `forwardagent` line prints the resolved socket path, and the whole check runs without connecting or touching any key file.

> **Do not add `IdentitiesOnly yes`** to `modules/guest/home/ssh.nix` or to a drop-in without also setting `IdentityFile` to the **public** key. With no `IdentityFile`, `IdentitiesOnly` suppresses agent identities outright — the agent is offered nothing, and a working setup looks convincingly broken.

## GUI and Display

**The guest can put a window on your host compositor**, through waypipe — no special flag, no virtio-gpu, no special hypervisor. That is the supported path, described in §1 below. Only a Wayland compositor is needed, and only on the host.

A second path exists behind `permafrost.gui = true` in `modules/guest/identity.nix`, **off by default**. It gives the guest `microvm.graphics.enable`: a host-side `crosvm device gpu` bridged to your compositor, plus `wayland-proxy-virtwl` as a systemd user service in the guest. It buys "ssh in first, then launch anything" and Xwayland for X11 clients — but it is upstream-fragile, needing three separate version pins to work at all (see §2). Flip it in `modules/guest/identity.nix` if you want it.

The toolkit environment — `NIXOS_OZONE_WL=1`, `LIBGL_ALWAYS_SOFTWARE=1`, `QT_QPA_PLATFORM`, `GDK_BACKEND`, `XDG_SESSION_TYPE` — is set unconditionally in `modules/guest/base.nix`, independent of `permafrost.gui`, because both paths need it. Without `NIXOS_OZONE_WL` an Electron build picks its X11 backend and dies on `Missing X server or $DISPLAY`. `WAYLAND_DISPLAY` is deliberately *not* set globally: waypipe exports its own for the process it launches.

### 1. waypipe over SSH — the default path

`waypipe` is installed on the host (`modules/host/bridge.nix`) and on the guest (`modules/guest/base.nix`), independent of `permafrost.gui`. It needs no virtio-gpu, no compositor in the guest, and no special hypervisor — only the binary on both ends, plus sshd:

```bash
waypipe --no-gpu ssh agent@192.168.33.10 <app>
```

`--no-gpu` hides the `wayland-drm` and `linux-dmabuf` globals from the guest. The guest has no render node, so any client that negotiates dmabuf buffers has nowhere to allocate them; blocking the globals pushes it onto `wl_shm`, which is waypipe's primary transport and the only one that can work here.

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

That same trick reaches a guest still running an older store closure than the host's
current config, mismatched `waypipe` version included.

Upstream's `run-waypipe` wrapper (vsock, `-s 2:6000`) is *not* usable as-is here: cloud-hypervisor multiplexes guest vsock ports onto `<socket>_<port>` UNIX sockets on the host, so a host-side `waypipe --vsock` client cannot bind `AF_VSOCK` directly. Use the SSH transport above.

Rendering is Mesa software rasterisation (llvmpipe) — enough for browser automation, headless Chromium, and Electron-based tools. No hardware GPU is exposed to the guest.

#### Electron and Chromium apps need GPU flags

The guest has no `/dev/dri`, and Chromium's Ozone/Wayland backend does not fall back gracefully. It looks up a DRM *render node* to build a GBM device and initialises EGL on that, so with no node the GPU process dies and viz restarts it in a loop:

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

`programs.nix-ld` is enabled on the guest (`modules/guest/base.nix`). Agents frequently fetch prebuilt binaries — toolchains, LSP servers, application "hosts" downloaded at first run — and those are foreign ELFs asking for `/lib64/ld-linux-x86-64.so.2`, which NixOS does not otherwise provide. Without nix-ld they fail at exec with a bare `No such file or directory` that names the binary rather than the missing interpreter. If such a binary still fails on a missing `.so`, add the library to `programs.nix-ld.libraries`.

### 2. The in-guest proxy — opt in with `permafrost.gui = true`

Setting `permafrost.gui = true` additionally enables `microvm.graphics`. On the host, microvm.nix starts a `crosvm device gpu` bridged to the invoking session's compositor; in the guest, `wayland-proxy-virtwl` runs as a systemd **user** service serving `/run/user/1000/wayland-1`. Because it is a user service, any session opened later can reach it:

```bash
sudo -E nix run .#permafrost   # -E is required here, and only here — see below
ssh agent@192.168.33.10
<electron-app>                 # WAYLAND_DISPLAY=wayland-1 is already set
```

X11 clients work too: the proxy runs `--x-display=0`, so `DISPLAY=:0` reaches an Xwayland server *inside the guest*. Nothing needs X11 on the host, and sshd needs no `X11Forwarding`.

**`-E` belongs to this path alone.** microvm.nix's preStart runs `crosvm device gpu --wayland-sock $XDG_RUNTIME_DIR/$WAYLAND_DISPLAY` verbatim under a root systemd unit, so both variables have to survive `sudo`. With `permafrost.gui = false` nothing consumes them — the compositor preflight below is emitted into the runner script only under `gui = true`, and the default launch neither needs a compositor nor cares whether those variables are set. Launch the default guest with plain `sudo`.

The runner preflights for a compositor and exits with an explanation if there is none — without that check, microvm.nix's preStart backgrounds `crosvm device gpu` and then spins in `while ! [ -S gpu.sock ]`, which never terminates when crosvm has nothing to attach to. The declarative fleet path cannot serve GUI at all, since its systemd unit has no session compositor.

**Why this is off by default.** It rests on three version pins that upstream does not currently hold together:

1. `cloud-hypervisor-graphics` comes from Spectrum's virtio-gpu patches, which apply only to cloud-hypervisor 51.0, while nixpkgs ships 53.0 (`overlays/cloud-hypervisor-graphics.nix`). Enabling `permafrost.gui` therefore builds cloud-hypervisor from source.
2. That fork requests `GET_SHARED_MEMORY_REGIONS` (message 1004, protocol bit `0x8000_0000`), which crosvm has since replaced with the standardized `SHMEM_MAP`. Hence the `nixpkgs-crosvm` pin in `flake.nix`; without it the guest dies at boot with `VhostUserGetSharedMemoryRegions(Disconnected)`.
3. That older crosvm links against glibc 2.40 while the host's Mesa needs `GLIBC_ABI_GNU2_TLS`, so its Mesa loader is redirected to its own generation (`modules/_pkgs/crosvm-graphics.nix`). Without that, rutabaga falls back to a 2D backend and the guest reports `invalid capset id 4294967295` — no cross-domain context, so the proxy cannot work.

Extra variables inside a `permafrost.gui = true` guest (`modules/guest/graphics.nix`): `WAYLAND_DISPLAY=wayland-1` and `DISPLAY=:0`. Diagnostics when nothing appears:

```bash
# host, while the VM runs
pgrep -af 'crosvm device gpu'
ss -lx | grep gpu.sock

# guest
systemctl --user status wayland-proxy
ls -l /run/user/1000/wayland-1
```

### Choosing between them

| | waypipe (default) | `permafrost.gui = true` proxy |
| :--- | :--- | :--- |
| Launch an app after logging in | Only inside a shell started by waypipe | Yes |
| Extra build cost | None | cloud-hypervisor 51.0 from source |
| Version pins required | None | Three (see above) |
| Needs a compositor in the launching session | At `waypipe ssh` time | At VM launch |
| X11 clients in the guest | No | Yes, `DISPLAY=:0` |
