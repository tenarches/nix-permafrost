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

## Lifecycle Management

Sandboxes can be run in the foreground (interactive) or in the background (detached). The runner script supports several subcommands:

- **`run` (default)**: Launches the VM in the foreground with an interactive serial console attached to your terminal. This is the standard "JIT" mode.
- **`start`**: Launches the VM in the background as a detached `systemd` service. This is ideal for long-running agents or servers.
- **`stop`**: Gracefully terminates the sandbox and cleans up all host-side resources (network bridges, sockets, mounts).
- **`status`**: Reports the current execution state, including the guest IP address and VSOCK CID.

**Example:**
```bash
# Start an agent in the background
sudo nix run .#claude -- start

# Check its IP
sudo nix run .#claude -- status

# Stop it when finished
sudo nix run .#claude -- stop
```

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

## SSH Access

Every sandbox is pre-configured with OpenSSH. Authentication is strictly key-based and uses a **Shared Directory** pattern (via `virtiofs`) to inject your host's keys at runtime. This ensures that changing your SSH keys never triggers a Nix rebuild of the VM.

### Key Injection

At launch, the runner automatically collects public keys from:
1. Your active **`ssh-agent`** (via `ssh-add -L`).
2. The **`AGENT_PUBKEYS`** environment variable.

The runner creates an ephemeral `ssh-keys` directory on the host, populates it with these keys for both the `agent` and `root` users, and shares it with the guest. The guest is configured to trust these keys for authentication.

**Note:** If you run the sandbox via `sudo`, the runner will attempt to auto-detect your user's SSH agent socket in `/run/user/$(id -u $SUDO_USER)`.

### Recommended SSH Config

Add the following to your `~/.ssh/config` for easy access:

```ssh
Host permafrost-*
    User agent
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null

# Example for TCP connection (requires 'status' to get IP)
Host permafrost-claude
    HostName 192.168.33.10
```

## Builder-Verifier (BV) Workflow

The `bv` agent implements an autonomous "Builder-Verifier" dual-agent architecture. It uses a high-capability builder (Gemini) and a specialized local verifier (Qwen) to automate code generation with an integrated audit loop.

### Launching the BV Environment

```bash
sudo nix run .#bv
```

Once inside the VM, you have two primary ways to execute tasks.

### Mode 1: Interactive (TMUX)

This mode is recommended for developing prompts, debugging agent behavior, or when you want to watch the agents work in real-time. It uses a four-pane tmux layout:

1.  **Start TMUX:** `tmux new-session -s bv`
2.  **Split Panes:** Set up the panes for Builder, Verifier, Coordinator Log, and Session Watcher.
3.  **Run Coordinator:** Use the provided script to manage the handoff:
    ```bash
    cd ~/bv/orchestrator
    ./coordinator.sh path/to/task.md
    ```

The coordinator will prompt the builder, wait for completion, and then automatically trigger the verifier to audit the session.

### Mode 2: Headless (Orchestrator)

This mode is ideal for stable workflows and automated runs. The orchestrator manages the entire lifecycle (Build -> Lint -> Verify) and streams human-readable events to your terminal.

```bash
cd ~/bv/orchestrator
npm start -- --task "Implement a JWT authentication service with Fastify and jose"
```

The orchestrator will:
1.  **Prime** the builder with codebase context.
2.  **Execute** the build phase.
3.  **Run** deterministic linting checks (`tsc`, `eslint`).
4.  **Audit** the session using the Verifier agent.
5.  **Retry** up to 2 times if verification or linting fails, providing the builder with specific feedback.

### Writing Effective Tasks

For the BV system to be effective, tasks should include clear **Acceptance Criteria**. The Verifier audits the session against these criteria.

**Example Task Structure:**
```markdown
/skill:prime

---
PROJECT TYPE: existing
TASK: Add refresh token rotation to the auth service.

SCOPE:
- Work within: src/auth/
- Target branch: feature/jwt-rotation

ACCEPTANCE CRITERIA:
1. src/auth/token.ts exports rotateRefreshToken
2. Old refresh token is revoked in Redis before new pair is issued
3. npm test exits 0
```

### External Tools (MCP)

The builder has access to Model Context Protocol (MCP) servers via the `mcporter` bridge. To use it:
- Invoke the skill: `/skill:mcporter`
- Call tools: `npx mcporter call github.create_issue ...`
- Discover servers: `npx mcporter list`

Agents with `gui = true` in their inventory spec get the host's Wayland socket mounted into the guest via `virtiofs`. The runner auto-detects the active Wayland socket on the host (defaulting to `wayland-0`, probing if necessary).

Rendering uses Mesa software rasterisation (llvmpipe). This is sufficient for browser automation, headless Chromium, and Electron-based tools. Hardware GPU acceleration is intentionally not exposed — sharing `/dev/dri` character devices through a virtiofsd namespace sandbox is incompatible with the seccomp allowlist required for namespace isolation.

Environment variables set automatically inside GUI-enabled guests:
- `WAYLAND_DISPLAY` — auto-detected from the host
- `XDG_RUNTIME_DIR=/run/user/1000`
- `NIXOS_OZONE_WL=1` — enables Ozone/Wayland backend for Electron apps
- `LIBGL_ALWAYS_SOFTWARE=1` — forces Mesa llvmpipe; skips hardware DRI probe
- `WLR_RENDERER_ALLOW_SOFTWARE=1` — required for wlroots-based compositors
