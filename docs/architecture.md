# Architecture Deep Dive

Extended diagrams covering subsystems not shown in the [main README](../README.md). Start there for the system overview, security model, lifecycle, filesystem layout, and secret injection pipeline.

---

## Flake Input Graph

All inputs pin `nixpkgs.follows` to a single `nixpkgs` instance, eliminating version drift across the entire dependency tree.

```mermaid
graph LR
    NIXPKGS["nixpkgs<br/>(nixos-unstable)"]

    FP["flake-parts"] -->|structures| FLAKE["flake.nix"]
    NIXPKGS -->|follows| MVM["microvm.nix"]
    NIXPKGS -->|follows| LLM["llm-agents.nix"]
    NIXPKGS -->|follows| MCP["mcp-servers-nix"]
    NIXPKGS -->|follows| HM["home-manager"]
    NIXPKGS -->|follows| NV["nixvim"]
    NIXPKGS -->|follows| SOPS["sops-nix"]
    NIXPKGS -->|follows| DEV["devenv"]
    NIXPKGS -->|follows| PCH["pre-commit-hooks"]

    MVM -->|"VM runtime"| FLAKE
    LLM -->|"agent CLIs"| FLAKE
    MCP -->|"MCP tool pkgs"| FLAKE
    HM -->|"user env mgmt"| FLAKE
    NV -->|"editor config"| FLAKE
    SOPS -->|"secret decrypt"| FLAKE
    DEV -->|"dev shells"| FLAKE
    PCH -->|"code quality"| FLAKE
    NIXPKGS -->|"base packages"| FLAKE

    style NIXPKGS fill:#4361ee,stroke:#3a0ca3,color:#fff,stroke-width:3px
    style FLAKE fill:#f72585,stroke:#b5179e,color:#fff,stroke-width:3px
    style MVM fill:#7209b7,stroke:#560bad,color:#fff
    style LLM fill:#7209b7,stroke:#560bad,color:#fff
    style MCP fill:#7209b7,stroke:#560bad,color:#fff
    style HM fill:#3a0ca3,stroke:#560bad,color:#fff
    style NV fill:#3a0ca3,stroke:#560bad,color:#fff
    style SOPS fill:#3a0ca3,stroke:#560bad,color:#fff
```

---

## Module Composition

The flake produces two output categories: **per-system packages** (the runner scripts you execute) and a **flake-wide NixOS configuration** (for deploying Permafrost as a full host).

```mermaid
graph TD
    FLAKE["flake.nix"]

    subgraph PER_SYSTEM["perSystem (x86_64-linux, aarch64-linux)"]
        DEVSHELL["devShells.default<br/>sops + age + virtiofsd"]
        FMT["formatter<br/>nixfmt"]
        HOOKS["pre-commit hooks<br/>nixfmt, deadnix, statix"]
        RUNNERS["packages.*<br/>(runners.nix)"]
    end

    subgraph FLAKE_WIDE["flake (system-independent)"]
        NIXOS_CFG["nixosConfigurations<br/>.permafrost"]
        MODULES["nixosModules<br/>(reusable)"]
    end

    FLAKE --> PER_SYSTEM
    FLAKE --> FLAKE_WIDE

    RUNNERS -->|"mkRunner<br/>per agent spec"| INV["inventory.nix<br/>(agent registry)"]

    NIXOS_CFG --> HOST_MOD["host.nix<br/>bridge + NAT"]
    NIXOS_CFG --> SEC_MOD["secrets.nix<br/>sops-nix + TPM"]
    NIXOS_CFG --> AGT_MOD["agents.nix<br/>mkAgentVm loop"]
    AGT_MOD --> INV

    subgraph GUEST_MODULES["Guest VM Module Stack"]
        AB["agent-base.nix<br/>hypervisor, filesystems,<br/>user, packages"]
        AE["agent-environment.nix<br/>home-manager: tmux,<br/>uv, nodejs"]
        NVIM["programs/nixvim.nix<br/>editor via nixvim"]
        CRED["microvm-credential-fix.nix<br/>OEM string injection"]
    end

    AB --> AE
    AE --> NVIM
    AB --> CRED

    MODULES -->|"agent-base"| AB
    MODULES -->|"host-bridge"| HOST_MOD

    style FLAKE fill:#f72585,stroke:#b5179e,color:#fff,stroke-width:3px
    style PER_SYSTEM fill:#4361ee22,stroke:#4361ee
    style FLAKE_WIDE fill:#7209b722,stroke:#7209b7
    style GUEST_MODULES fill:#06d6a022,stroke:#06d6a0
    style INV fill:#f77f00,stroke:#d62828,color:#fff
```

---

## Network Architecture

Each guest gets a `tap` interface bridged to `microbr`. The host performs NAT to route guest traffic to the internet. `cloud-hypervisor` does not support user-mode SLIRP, which is why `sudo` is required — the host must create and configure TAP devices.

```mermaid
graph TB
    INET["Internet"]

    subgraph HOST["Host"]
        EXT["External NIC<br/>(wlp4s0)"]
        IPTABLES["iptables NAT<br/>MASQUERADE<br/>192.168.33.0/24"]
        FWD["ip_forward = 1"]
        BRIDGE["microbr<br/>192.168.33.1/24"]

        EXT --- IPTABLES --- FWD --- BRIDGE
    end

    INET <-->|"routed traffic"| EXT

    subgraph GUESTS["Guest VMs (one per inventory spec)"]
        TAP_N["tap: microvm-(name)"] --> VM_N["Agent VM<br/>192.168.33.x/24<br/>gw .33.1"]
    end

    BRIDGE --- TAP_N

    DNS["DNS servers<br/>(per agent-base.nix)"]
    VM_N -.->|resolv| DNS

    style HOST fill:#0f3460,stroke:#16213e,color:#fff
    style BRIDGE fill:#4361ee,stroke:#3a0ca3,color:#fff,stroke-width:3px
    style GUESTS fill:#1a1a2e22,stroke:#e94560
    style INET fill:#06d6a0,color:#000,stroke-width:3px
```

---

## Overlay & Package Pipeline

The Python MCP overlay fixes upstream build issues and feeds into the MCP server package set. The overlay ordering matters — `python-mcp.nix` must apply before `mcp-servers-nix.overlays.default` so the patched Python packages are visible when MCP server derivations are evaluated.

```mermaid
graph LR
    subgraph OVERLAYS["Overlay Stack (order matters)"]
        PY_MCP["1. overlays/python-mcp.nix<br/>Fix: fastmcp, fakeredis,<br/>pydocket, mcp-nixos"]
        MCP_OV["2. mcp-servers-nix<br/>.overlays.default"]
    end

    NIXPKGS["nixpkgs<br/>(unstable)"] --> PY_MCP
    PY_MCP -->|"patched pkgs"| MCP_OV

    MCP_OV --> PKGS["Available MCP Packages"]

    PKGS --> INV["inventory.nix<br/>(per-agent extraPackages)"]

    style OVERLAYS fill:#7209b722,stroke:#7209b7
    style NIXPKGS fill:#4361ee,stroke:#3a0ca3,color:#fff
    style INV fill:#f77f00,stroke:#d62828,color:#fff
```

---

## GUI Passthrough

Agents with `gui = true` in their inventory spec get Wayland/GPU passthrough through the KVM boundary, enabling graphical applications at near-native performance.

```mermaid
graph LR
    subgraph HOST["Host"]
        WL_SOCK["/run/user/1000/<br/>wayland-*"]
        DRI["/dev/dri<br/>(GPU devices)"]
    end

    subgraph VFS["virtiofs"]
        WL_VFS["wayland.sock"]
        DRI_VFS["dri.sock"]
    end

    subgraph GUEST["GUI-enabled VM"]
        G_WL["/run/user/1000/<br/>wayland-*"]
        G_DRI["/dev/dri"]
        ENV["WAYLAND_DISPLAY<br/>XDG_RUNTIME_DIR<br/>NIXOS_OZONE_WL=1"]
        ELECTRON["Electron App<br/>(near-native perf)"]

        G_WL --> ELECTRON
        G_DRI --> ELECTRON
        ENV --> ELECTRON
    end

    WL_SOCK --> WL_VFS --> G_WL
    DRI --> DRI_VFS --> G_DRI

    style HOST fill:#0f3460,color:#fff
    style GUEST fill:#533483,color:#fff
    style ELECTRON fill:#06d6a0,color:#000,stroke-width:2px
```

---

## Dual Execution Modes

The same `inventory.nix` spec powers two different execution paths. **Standalone mode** (`nix run`) is for developers running agents on any NixOS machine. **Fleet mode** (`nixosConfigurations.permafrost`) is for deploying a dedicated multi-agent host.

```mermaid
graph TD
    INV["inventory.nix<br/>(single source of truth)"]

    subgraph STANDALONE["Standalone Mode: nix run .#(name)"]
        RUN["runners.nix<br/>mkRunner"]
        SCRIPT["Shell script per agent"]
        JIT["JIT bridge + NAT + virtiofsd"]
        SD_RUN["systemd-run transient unit"]
        CHV1["cloud-hypervisor"]
    end

    subgraph FLEET["Fleet Mode: nixosConfigurations.permafrost"]
        AGENTS["agents.nix<br/>mkAgentVm"]
        MVM_VMS["microvm.vms.<name>"]
        HOST_SVC["Persistent systemd services"]
        CHV2["cloud-hypervisor"]
    end

    INV --> RUN
    INV --> AGENTS

    RUN --> SCRIPT --> JIT --> SD_RUN --> CHV1
    AGENTS --> MVM_VMS --> HOST_SVC --> CHV2

    style INV fill:#f77f00,stroke:#d62828,color:#fff,stroke-width:3px
    style STANDALONE fill:#4361ee22,stroke:#4361ee
    style FLEET fill:#7209b722,stroke:#7209b7
```
