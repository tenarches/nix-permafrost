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

### Available Agents

- **`claude-cluster`**: Ships with `claude-code` and the open-source `openclaude` CLI. Best for complex coding tasks.
- **`gemini-agent`**: Ships with `gemini-cli` for specialized Google Gemini interaction.
- **`opencode-agent`**: Ships with `opencode` for Open-source LLM orchestration.
- **`pi-agent`**: Ships with `pi` for Inflection interaction.
- **`antigravity`**: A Wayland-native Electron environment with hardware acceleration.

## Environment Persistence and Tools

### Console and Terminal
The VM console attaches directly to your active terminal with an automatic login as the `agent` user. This is the primary and most secure method of interaction.
*   **Disconnecting:** To terminate the hypervisor and destroy the sandbox, press `Ctrl-a` then `x`.

### TMUX (Highly Recommended)
Every sandbox drops you into a shell where `tmux` is readily available. Because LLM agents often run long, autonomous loops, executing your workflow inside a `tmux` session ensures that an accidental terminal disconnect does not terminate the task.

### GUI and Wayland Passthrough
The `antigravity` agent leverages `virtiofs` to mount the host's `/run/user/1000/wayland-0` socket and `/dev/dri` directly into the guest. This provides near-native GUI performance for Electron-based agent tools inside the isolated KVM boundary.
