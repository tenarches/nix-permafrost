# Permafrost Technical Reference

This document serves as a densely packed technical reference for the underlying architecture, module definitions, and hypervisor constraints of Project Permafrost.

## The `cloud-hypervisor` Backend

We specifically target `cloud-hypervisor` (Rust-based) over QEMU to minimize the virtualization attack surface while retaining critical features like `virtiofs`.

### Networking
Unlike user-mode SLIRP networking (which `cloud-hypervisor` does not support), Permafrost uses `tap` interfaces. This is why `sudo` is required to launch the VMs: the host must create and configure the `tap` device (e.g., `vm-claud` for `claude`) to route traffic to the external `wlp4s0` interface via the `microbr` bridge.

## Module Registry (`modules/inventory.nix`)

All agents are defined in a central registry. A standard definition looks like this:

```nix
claude = {
  name = "claude";
  ip = "192.168.33.10";
  mac = "02:00:00:00:00:10";
  vsockCid = 10;
  persistentShares = [
    { host = ".claude"; guest = ".claude"; }
    { host = ".claude.json"; guest = ".claude.json"; is_file = true; }
  ];
  extraPackages = [
    inputs.llm-agents.packages.${system}.claude-code
    openclaude
  ];
  credentials = {
    ANTHROPIC_API_KEY = "/run/secrets/anthropic-api-key";
  };
};
```
*Note: We vendor the `openclaude` module locally rather than relying on an external upstream flake, ensuring hermetic reliability.*

## Secret Injection Architecture

Handling secrets securely in declarative VMs is notoriously difficult. Permafrost achieves this without baking secrets into the Nix store.

1. **Host-Side Decryption:** The host unseals secrets (e.g., via `sops-nix` and a TPM) to protected directories like `/run/secrets/`.
2. **The `extraArgsScript` Workaround:** `cloud-hypervisor` lacks native parsing for `microvm.credentialFiles`. We overcome this in `modules/microvm-credential-fix.nix`. At VM launch time, this script reads the host secrets and dynamically constructs the `--platform oem_string=[]` arguments.
3. **Guest Consumption:** The guest kernel reads the OEM strings, and `systemd` mounts them to `/run/host/credentials/` where the agent process can securely consume them.
