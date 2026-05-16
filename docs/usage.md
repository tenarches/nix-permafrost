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
| **`antigravity`** | Web Browsing / GUI | Browser / GUI | Wayland passthrough; specialized for UI interaction. |
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
- **`~/workspace`**: Shared working directory across all agents.
- **`~/.agents`**: Shared state (memories, persistent context).
- **`~/bv`** (in `bv` VM): Houses session logs and mutable orchestrator state.

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

The verifier endpoint is hardcoded to `http://dualie.home.lan:8001/v1` in three places. If your llama.cpp server runs on a different host or port, update all three:

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

By default, both agents start in `~/workspace` (the shared workspace root). To target a specific project, set `BV_PROJECT_ROOT` before initializing:

```bash
export BV_PROJECT_ROOT=~/workspace/my-project
```

This affects the builder's and verifier's working directory in both interactive and headless modes. If unset, it defaults to `~/workspace`.

### Mode 1: Interactive (TMUX)
Best for watching the agents work or debugging prompts. This mode requires a specific 4-pane tmux layout which can be initialized automatically.

1.  **Initialize Layout:**
    ```bash
    cd ~/.bv-logic/orchestrator
    ./init-bv.sh
    ```
    This creates a tmux session named `bv` with the following layout:
    - **Top-Left (0.0):** Builder Agent (`pi`)
    - **Top-Right (0.2):** Verifier Agent (`pi`)
    - **Bottom-Left (0.1):** Coordinator Script
    - **Bottom-Right (0.3):** Live Session Log Watcher

2.  **Attach to Session:**
    ```bash
    tmux attach -t bv
    ```

3.  **Run a Task:**
    In the **bottom-left pane (0.1)**, run:
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

Agents with `gui = true` in their inventory spec get the host's Wayland socket mounted into the guest via `virtiofs`. The runner auto-detects the active Wayland socket on the host (defaulting to `wayland-0`, probing if necessary).

Rendering uses Mesa software rasterisation (llvmpipe). This is sufficient for browser automation, headless Chromium, and Electron-based tools. Hardware GPU acceleration is intentionally not exposed — sharing `/dev/dri` character devices through a virtiofsd namespace sandbox is incompatible with the seccomp allowlist required for namespace isolation.

Environment variables set automatically inside GUI-enabled guests:
- `WAYLAND_DISPLAY` — auto-detected from the host
- `XDG_RUNTIME_DIR=/run/user/1000`
- `NIXOS_OZONE_WL=1` — enables Ozone/Wayland backend for Electron apps
- `LIBGL_ALWAYS_SOFTWARE=1` — forces Mesa llvmpipe; skips hardware DRI probe
- `WLR_RENDERER_ALLOW_SOFTWARE=1` — required for wlroots-based compositors
