# Project Permafrost: Isolated Agent Sandbox Architecture

Permafrost is a declarative, hardware-isolated sandbox framework for executing LLM agents on NixOS. By utilizing **cloud-hypervisor** via `microvm.nix`, Permafrost enforces a rigorous KVM security boundary, ensuring that autonomous agents—which may execute arbitrary code or shell commands—remain strictly confined.

This repository demonstrates advanced declarative VM orchestration, zero-copy host-to-guest file sharing, and secure runtime secret injection.

## Documentation Hub

We maintain detailed, densely packed documentation to support developer adoption and architectural understanding:

1. **[Usage Guide](docs/usage.md)**: Instructions on running agents, managing environments, and handling Wayland/GUI passthrough.
2. **[Technical Reference](docs/reference.md)**: Deep dives into the `cloud-hypervisor` constraints, `tap` networking, and our custom systemd-credential injection logic.

## Quick Start

### Prerequisites
* **NixOS** host with KVM enabled.
* Flakes and `nix-command` enabled.
* A configured `microbr` bridge for NAT (see Reference).

### Launching an Agent
Due to the use of high-performance `tap` networking, root privileges are required to configure the host-side interfaces:

```bash
# Execute remotely:
sudo nix run github:tenarches/nix-permafrost#claude

# Or from a local clone:
sudo nix run .#claude
```

## Key Features
- **Security First**: Rust-based `cloud-hypervisor` backend.
- **Zero-Copy**: `virtiofs` enables instant mounting of the host Nix store and live agent workspaces.
- **Hermetic Secrets**: Keys are injected at runtime via OEM strings; they never touch the Nix store or the guest disk.
- **Ephemeral State**: Guest `$HOME` is mounted on `tmpfs`. The sandbox is completely destroyed upon termination (`Ctrl-a x`).
