# Design Spec: JIT MicroVM Lifecycle & SSH Patterns

**Date:** 2026-05-04  
**Status:** Draft  
**Topic:** Implementing a robust, pure, and background-friendly lifecycle for Nix Flake-based MicroVMs with integrated SSH access.

---

## 1. Objective

Enable a "Just-In-Time" (JIT) operational pattern for agentic coding environments that supports background execution, graceful lifecycle management, and secure SSH access without compromising the "purity" of the Nix build or requiring permanent host modifications.

## 2. Architecture

### 2.1 Lifecycle Controller (`runners.nix`)

The runner script generated for each agent will be refactored into a multi-command CLI tool.

| Command | Action | Implementation Detail |
| :--- | :--- | :--- |
| **(None)** | Foreground Launch | Launches the VM with `--pty` and `--wait`. Standard interactive console. |
| **`start`** | Background Launch | Launches the VM via `systemd-run` without `--pty` or `--wait`. Detaches immediately. |
| **`stop`** | Graceful Shutdown | Sends `SIGTERM` to the VM's PID or uses `systemctl stop` on the transient unit. |
| **`status`** | Introspection | Reads the ephemeral `RuntimeDirectory` (`/run/microvm-<name>/`) to report IP, VSOCK CID, and PID. |

### 2.2 Pure SSH Authentication ("Late Binding")

To prevent key changes from triggering Nix rebuilds, we use **Systemd Credentials**.

1.  **Host-side (Runner):**
    *   Reads keys from host `ssh-agent` (`ssh-add -L`).
    *   Appends keys from environment variable `AGENT_PUBKEYS`.
    *   Saves keys to `$SOCKET_DIR/ssh-keys`.
    *   Passes the file path to the hypervisor as a credential (e.g., `--oem-string` for Cloud-Hypervisor).
2.  **Guest-side (NixOS):**
    *   Configures `sshd` with `PasswordAuthentication = false` and `PermitRootLogin = "prohibit-password"`.
    *   Sets a `tmpfiles.rule` to symlink `/home/agent/.ssh/authorized_keys` to the systemd credential path (`/run/credentials/sshd.service/ssh.authorized_keys.agent`).

### 2.3 Dual-Mode Connectivity

Every VM exposes two methods for SSH connection:

1.  **TCP (Primary):** Accessible via the bridge IP (e.g., `192.168.33.XX`). Best for standard development tools.
2.  **VSOCK (Secondary/Robust):** Accessible via `socat` on the host. Bypasses the network stack entirely.

---

## 3. Component Specifications

### 3.1 `modules/agent-base.nix` Changes
*   Enable `services.openssh`.
*   Disable password/interactive auth.
*   Configure the `.ssh/authorized_keys` symlink to the systemd credential.

### 3.2 `runners.nix` Changes
*   Refactor the `runnerScript` template to use a `case` statement for subcommands.
*   Update the `LAUNCH_COMMAND` to include the `ssh-agent` lookup.
*   Modify the `systemd-run` invocation to support detached mode for the `start` command.

### 3.3 Documentation (`docs/usage.md`)
*   Add instructions for `start`/`stop`/`status`.
*   Provide a standardized SSH config template.

---

## 4. Usage Patterns

### CLI Examples
```bash
# Start background VM
sudo nix run .#claude -- start

# Check status
sudo nix run .#claude -- status

# Connect via SSH
ssh agent@192.168.33.10

# Stop VM
sudo nix run .#claude -- stop
```

### SSH Configuration Template
```ssh
Host permafrost-*
    User agent
    IdentityAgent ~/.ssh/agent.sock # Standard agent path
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null

Host permafrost-claude
    HostName 192.168.33.10
```

---

## 5. Security & Isolation

*   **No Root Passwords:** Root is only accessible via serial console or prohibit-password SSH.
*   **Pure Builds:** The Nix store paths are identical regardless of which user launches the VM or which keys are in their agent.
*   **Ephemeral Sockets:** All control sockets and PID files reside in `/run/microvm-<name>`, which is cleaned up automatically by systemd when the VM stops.
