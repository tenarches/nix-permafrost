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
| **`antigravity`** | Web Browsing / GUI | Browser / GUI | Wayland passthrough; specialized for UI interaction. |

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
- **`~/workspace`**: Shared working directory across all agents.
- **`~/.agents`**: Shared state (memories, persistent context).
- **`~/bv`** (in `bv` VM): Houses session logs and mutable orchestrator state.

## Builder-Verifier (BV) Workflow

The `bv` agent is the project's flagship "Agentic Harness." It implements an autonomous dual-agent architecture (Gemini Builder + Qwen Verifier).

### Initial Setup
Inside the `bv` VM, you must perform a one-time setup for the orchestrator dependencies:
```bash
cd ~/bv/orchestrator
npm install
```
*Note: The guest has internet access via host NAT for this step.*

### Mode 1: Interactive (TMUX)
Best for watching the agents work or debugging prompts.
1.  **Launch TMUX:** `tmux new-session -s bv`
2.  **Run Coordinator:**
    ```bash
    cd ~/bv/orchestrator
    ./coordinator.sh path/to/task.md
    ```
    The coordinator manages the handoff between the Builder (Pane 0.0) and the Verifier (Pane 0.1).

### Mode 2: Headless (Orchestrator)
Best for automated implementation and verification.
```bash
cd ~/bv/orchestrator
npm start -- --task "Implement a JWT authentication service"
```

The orchestrator executes a five-stage loop:
1.  **Prime:** Loads codebase context via the `prime` skill.
2.  **Build:** Builder implements the code and provides verifiable atomic claims.
3.  **Lint:** Runs `tsc` and `eslint` automatically.
4.  **Verify:** Verifier audits the session log against the claims.
5.  **Feedback:** Automatically retries up to 2 times on failure.

## External Tools (MCP)

The `bv` and `pi` agents have access to the **Model Context Protocol (MCP)** via the `mcporter` bridge.
- **Discover tools:** `npx mcporter list`
- **Call a tool:** `npx mcporter call <server>.<tool> key:value`
- **Config:** Managed declaratively in `~/.mcporter/mcporter.json`.

Agents with `gui = true` in their inventory spec get the host's Wayland socket mounted into the guest via `virtiofs`. The runner auto-detects the active Wayland socket on the host (defaulting to `wayland-0`, probing if necessary).

Rendering uses Mesa software rasterisation (llvmpipe). This is sufficient for browser automation, headless Chromium, and Electron-based tools. Hardware GPU acceleration is intentionally not exposed — sharing `/dev/dri` character devices through a virtiofsd namespace sandbox is incompatible with the seccomp allowlist required for namespace isolation.

Environment variables set automatically inside GUI-enabled guests:
- `WAYLAND_DISPLAY` — auto-detected from the host
- `XDG_RUNTIME_DIR=/run/user/1000`
- `NIXOS_OZONE_WL=1` — enables Ozone/Wayland backend for Electron apps
- `LIBGL_ALWAYS_SOFTWARE=1` — forces Mesa llvmpipe; skips hardware DRI probe
- `WLR_RENDERER_ALLOW_SOFTWARE=1` — required for wlroots-based compositors
