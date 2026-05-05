# JIT MicroVM Lifecycle & SSH Patterns Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement a subcommand-based lifecycle controller (start, stop, status) and pure SSH key injection for MicroVMs.

**Architecture:** Enhances `runners.nix` with subcommand logic and `modules/agent-base.nix` with systemd-credential-based SSH provisioning.

**Tech Stack:** Nix, Bash, Systemd, Cloud-Hypervisor/QEMU, OpenSSH.

---

### Task 1: Update Guest SSH Configuration

**Files:**
- Modify: `modules/agent-base.nix`

- [ ] **Step 1: Modify `modules/agent-base.nix` to enable SSH with systemd credentials**

```nixos
<<<<
  # Enable passwordless sudo for the wheel group
  security.sudo.wheelNeedsPassword = false;

  # Automatically symlink persistent mounts from /mnt/persist to home
====
  # Enable passwordless sudo for the wheel group
  security.sudo.wheelNeedsPassword = false;

  # SSH Configuration
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "prohibit-password";
    };
  };

  # Provision authorized_keys from systemd credentials (late binding)
  systemd.tmpfiles.rules = [
    "d /home/agent/.ssh 0700 agent users - -"
    "L+ /home/agent/.ssh/authorized_keys - - - - /run/credentials/sshd.service/ssh.authorized_keys.agent"
  ];

  # Automatically symlink persistent mounts from /mnt/persist to home
>>>>
```

- [ ] **Step 2: Verify Nix syntax**

Run: `nix-instantiate --parse modules/agent-base.nix > /dev/null`
Expected: Success (no output)

- [ ] **Step 3: Commit**

```bash
git add modules/agent-base.nix
git commit -m "feat: enable SSH with systemd-credential provisioning in agent-base"
```

---

### Task 2: Implement Runner Subcommand Logic

**Files:**
- Modify: `runners.nix`

- [ ] **Step 1: Refactor `runners.nix` to handle subcommands (start, stop, status)**

```nix
<<<<
      runnerScript = pkgs.writeShellScriptBin spec.name ''
        set -e
        # 1. Environment Detection
====
      runnerScript = pkgs.writeShellScriptBin spec.name ''
        set -e
        COMMAND="${"$"}{1:-run}"
        [ "$#" -gt 0 ] && shift

        # 1. Environment Detection
>>>>
```

- [ ] **Step 2: Add `ssh-agent` key collection to `LAUNCH_COMMAND`**

```nix
<<<<
        LAUNCH_COMMAND='
          # Start virtiofsd backends
====
        LAUNCH_COMMAND='
          # Provision SSH keys from host agent/env
          echo "Provisioning SSH keys..."
          mkdir -p "$SOCKET_DIR/creds"
          ssh-add -L > "$SOCKET_DIR/creds/ssh.authorized_keys.agent" || true
          if [ -n "$AGENT_PUBKEYS" ]; then
            echo "$AGENT_PUBKEYS" >> "$SOCKET_DIR/creds/ssh.authorized_keys.agent"
          fi

          # Start virtiofsd backends
>>>>
```

- [ ] **Step 3: Update `microvm-run` call to pass credentials**

```nix
<<<<
          ${nixosConfig.config.microvm.declaredRunner}/bin/microvm-run \
            --cmdline "wayland_display=$HOST_WAYLAND_DISPLAY " \
            --api-socket "$SOCKET_DIR/nixos.sock" \
            --vsock "cid=${toString spec.vsockCid},socket=$SOCKET_DIR/notify.vsock"
        '
====
          ${nixosConfig.config.microvm.declaredRunner}/bin/microvm-run \
            --cmdline "wayland_display=$HOST_WAYLAND_DISPLAY " \
            --api-socket "$SOCKET_DIR/nixos.sock" \
            --vsock "cid=${toString spec.vsockCid},socket=$SOCKET_DIR/notify.vsock" \
            --oem-string "io.systemd.credential:ssh.authorized_keys.agent=$(cat $SOCKET_DIR/creds/ssh.authorized_keys.agent)"
        '
>>>>
```

- [ ] **Step 4: Implement command dispatcher (start, stop, status)**

```nix
<<<<
        systemd-run \
          --pty \
          --wait \
          --collect \
          --service-type=exec \
====
        RUN_ARGS=(
          --collect
          --service-type=exec
          --property="RuntimeDirectory=$RUNTIME_NAME"
          --property="RuntimeDirectoryPreserve=no"
          --property="Environment=PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.bash pkgs.util-linux pkgs.openssh ]}"
          --property="Environment=REAL_HOME=$REAL_HOME"
          --property="Environment=HOST_XDG_RUNTIME_DIR=$HOST_XDG_RUNTIME_DIR"
          --property="Environment=HOST_WAYLAND_DISPLAY=$HOST_WAYLAND_DISPLAY"
          --property="Environment=SOCKET_DIR=$SOCKET_DIR"
          --property="Environment=RUNTIME_NAME=$RUNTIME_NAME"
          --description="Permafrost VM: ${spec.name}"
        )

        case "$COMMAND" in
          run)
            echo "Launching ${spec.name} in foreground..."
            systemd-run --pty --wait "${"$"}{RUN_ARGS[@]}" ${pkgs.bash}/bin/bash -c "$LAUNCH_COMMAND"
            ;;
          start)
            if systemctl is-active --quiet "run-$RUNTIME_NAME.service"; then
              echo "Error: ${spec.name} is already running."
              exit 1
            fi
            echo "Starting ${spec.name} in background..."
            systemd-run "${"$"}{RUN_ARGS[@]}" ${pkgs.bash}/bin/bash -c "$LAUNCH_COMMAND"
            echo "${spec.name} started. Use 'nix run .#${spec.name} -- status' for details."
            ;;
          stop)
            echo "Stopping ${spec.name}..."
            systemctl stop "run-$RUNTIME_NAME.service"
            ;;
          status)
            if systemctl is-active --quiet "run-$RUNTIME_NAME.service"; then
              echo "Status: ${spec.name} is RUNNING"
              echo "IP: ${spec.ip}"
              echo "VSOCK CID: ${toString spec.vsockCid}"
              echo "Runtime Dir: $SOCKET_DIR"
            else
              echo "Status: ${spec.name} is STOPPED"
            fi
            ;;
          *)
            echo "Unknown command: $COMMAND"
            echo "Usage: nix run .#${spec.name} -- [run|start|stop|status]"
            exit 1
            ;;
        esac
>>>>
```

- [ ] **Step 5: Verify Nix syntax**

Run: `nix-instantiate --parse runners.nix > /dev/null`
Expected: Success

- [ ] **Step 6: Commit**

```bash
git add runners.nix
git commit -m "feat: implement start/stop/status subcommands and SSH key injection in runners"
```

---

### Task 3: Update Documentation

**Files:**
- Modify: `docs/usage.md`

- [ ] **Step 1: Add Lifecycle and SSH documentation to `docs/usage.md`**

```markdown
<<<<
## Console and Terminal

The VM console attaches directly to your active terminal...
====
## Lifecycle Management

Agents can be managed via subcommands passed to the runner:

- **Foreground (Interactive):** `sudo nix run .#<agent>`
- **Background (Daemon):** `sudo nix run .#<agent> -- start`
- **Stop:** `sudo nix run .#<agent> -- stop`
- **Status:** `sudo nix run .#<agent> -- status`

## SSH Access

Every sandbox is pre-configured with a hardened SSH daemon. Authentication is strictly key-based; passwords are disabled.

### Key Injection

At launch, the runner automatically collects public keys from your host's active `ssh-agent` and injects them into the guest. You can also provide extra keys via the `AGENT_PUBKEYS` environment variable.

### Connecting

Use the IP address reported by the `status` command.

**SSH Config Template:**

```ssh
Host permafrost-*
    User agent
    IdentityAgent ~/.ssh/agent.sock # Update to your agent path
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null

Host permafrost-claude
    HostName 192.168.33.10 # Example IP
```
>>>>
```

- [ ] **Step 2: Commit**

```bash
git add docs/usage.md
git commit -m "docs: add lifecycle and ssh usage instructions"
```

---

### Task 4: Verification

- [ ] **Step 1: Build the default agent**

Run: `nix build .#claude`
Expected: Success

- [ ] **Step 2: Test 'start' command**

Run: `sudo ./result/bin/claude start`
Expected: "Starting claude in background..."

- [ ] **Step 3: Test 'status' command**

Run: `sudo ./result/bin/claude status`
Expected: "Status: claude is RUNNING" and correct IP/CID.

- [ ] **Step 4: Test SSH connection**

Run: `ssh -o StrictHostKeyChecking=no agent@$(sudo ./result/bin/claude status | grep IP | awk '{print $2}') "whoami"`
Expected: `agent`

- [ ] **Step 5: Test 'stop' command**

Run: `sudo ./result/bin/claude stop`
Expected: VM stops and `status` reports STOPPED.
