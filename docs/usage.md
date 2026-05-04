# Using Project Permafrost Sandboxes

Permafrost is designed for high-capability, declarative agent execution. Because we enforce a strict KVM boundary using `cloud-hypervisor` and rely on high-performance `virtiofs` and `tap` networking, executing a sandbox requires root privileges to configure the host-side network interfaces.

## Launching an Agent (Local vs. Remote)

Whether you are a local developer or executing an agent Just-In-Time (JIT) from a remote repository, the workflow is identical:

**JIT (Remote):**
```bash
sudo nix run github:tenarches/nix-permafrost#<agent-name>
```

**Local Checkout:**
```bash
sudo nix run .#<agent-name>
```

Running without specifying an agent name (`sudo nix run .#`) launches the default agent.

To list all available agents:
```bash
nix flake show
```

Agents are defined declaratively in `modules/inventory.nix`. Each spec declares the agent's network identity, CLI tools, MCP servers, credentials, and persistent shares. Adding a new agent means adding a new entry to the inventory and a corresponding runner in `runners.nix`.

## Console and Terminal

The VM console attaches directly to your active terminal with an automatic login as the `agent` user. This is the primary and most secure method of interaction.

**Terminating the sandbox:** Press `Ctrl-a` then `x`. This kills the hypervisor and destroys all ephemeral state. The `systemd-run` transient unit automatically cleans up all sockets, PIDs, and temporary mounts.

### TMUX

Every sandbox ships with `tmux` pre-configured. Because LLM agents often run long, autonomous loops, executing your workflow inside a `tmux` session ensures that an accidental terminal disconnect does not terminate the task.

The tmux prefix is `Ctrl-a` (same as the hypervisor escape). To send a literal `Ctrl-a` to tmux when inside the VM, press `Ctrl-a` twice (`Ctrl-a Ctrl-a`). To terminate the VM from within tmux, detach first (`Ctrl-a d`), then press `Ctrl-a x` at the bare console.

## Persistence

### What Persists (survives VM termination)

Every agent gets two **global** shared directories mounted from the host via `virtiofs`:

- `~/workspace` — shared working directory across all agents
- `~/.agents` — shared agent coordination/state

Each agent spec can also declare **per-agent persistent shares** via the `persistentShares` field in `inventory.nix`. These map host directories under `$HOME` into the guest at `~/`, preserving agent-specific configuration between sessions. The launching user's home directory is detected via `$SUDO_USER`.

### What Is Ephemeral (destroyed on exit)

- **`/home/agent`**: Mounted on `tmpfs`. All dotfiles and local state not covered by persistent shares are lost.
- **`/nix/.rw-store`**: A tmpfs overlay atop the read-only host Nix store. Any `nix-build` or `nix-env` operations inside the guest are temporary.

## Credentials

API keys declared in an agent's `credentials` field are injected automatically at VM launch. The host decrypts them via `sops-nix` and passes them into the guest as OEM strings — they never touch the Nix store or the guest disk. See the [Secret Injection Pipeline](../README.md#secret-injection-pipeline) diagram for the full flow.

## GUI and Wayland Passthrough

Agents with `gui = true` in their inventory spec get the host's Wayland socket mounted into the guest via `virtiofs`. The runner auto-detects the active Wayland socket on the host (defaulting to `wayland-0`, probing if necessary).

Rendering uses Mesa software rasterisation (llvmpipe). This is sufficient for browser automation, headless Chromium, and Electron-based tools. Hardware GPU acceleration is intentionally not exposed — sharing `/dev/dri` character devices through a virtiofsd namespace sandbox is incompatible with the seccomp allowlist required for namespace isolation.

Environment variables set automatically inside GUI-enabled guests:
- `WAYLAND_DISPLAY` — auto-detected from the host
- `XDG_RUNTIME_DIR=/run/user/1000`
- `NIXOS_OZONE_WL=1` — enables Ozone/Wayland backend for Electron apps
- `LIBGL_ALWAYS_SOFTWARE=1` — forces Mesa llvmpipe; skips hardware DRI probe
- `WLR_RENDERER_ALLOW_SOFTWARE=1` — required for wlroots-based compositors
