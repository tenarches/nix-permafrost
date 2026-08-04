# Project Permafrost: Isolated Agent Sandbox Architecture

Permafrost is a declarative, hardware-isolated sandbox framework for executing LLM agents on NixOS. By utilizing **cloud-hypervisor** via `microvm.nix`, Permafrost enforces a rigorous KVM security boundary, ensuring that autonomous agents—which may execute arbitrary code or shell commands—remain strictly confined.

### Autonomous Workflows: Builder-Verifier (BV)

Beyond simple sandboxing, Permafrost implements the **Builder-Verifier** architecture—a dual-agent system where a creative Builder agent (Gemini) implements code while a specialized Verifier agent (Qwen) audits the session log to validate atomic claims before any human review.

```mermaid
graph TB
    subgraph HOST["NixOS Host (permafrost)"]
...
        NS["/nix/store"]
        SOPS["sops-nix<br/>Secrets Engine"]
        BR["microbr bridge<br/>192.168.33.1/24"]
        NAT["NAT + IP Forward"]
        EXT["External NIC<br/>(wlp4s0)"]

        SOPS -->|"decrypt via TPM"| SEC["/run/secrets/*"]
        BR --- NAT --- EXT
    end

    subgraph KVM_BOUNDARY["KVM Security Boundary (cloud-hypervisor)"]
        direction LR
        subgraph VM_N["Agent VM (per inventory spec)"]
            AGENT_CLI["Agent CLI +<br/>MCP servers"]
            CREDS["Injected credentials"]
            PERSIST["Persistent shares"]
            TMPFS["Ephemeral tmpfs home"]
        end
    end

    NS --->|"virtiofs<br/>(read-only)"| VM_N
    SEC --->|"OEM strings<br/>(runtime inject)"| VM_N
    BR ---|"tap interface<br/>(bridged)"| VM_N

    style KVM_BOUNDARY fill:#1a1a2e,stroke:#e94560,stroke-width:3px,color:#fff
    style HOST fill:#0f3460,stroke:#16213e,stroke-width:2px,color:#fff
    style VM_N fill:#533483,stroke:#e94560,color:#fff
```

---

## Quick Start

### Prerequisites
* **NixOS** host with KVM enabled.
* Flakes and `nix-command` enabled.
* A configured `microbr` bridge for NAT (see [Reference](docs/reference.md)).

### Launching an Agent
Due to the use of high-performance `tap` networking, root privileges are required to configure the host-side interfaces:

```bash
# Execute remotely:
sudo nix run github:tenarches/nix-permafrost#claude

# Or from a local clone:
sudo nix run .#claude
```

---

## Design Principles

```mermaid
mindmap
  root((Permafrost))
    Security First
      KVM hardware isolation
      Rust-based cloud-hypervisor
      Minimal attack surface
      Secrets never in Nix store
    Ephemeral by Default
      tmpfs guest home
      Destroyed on Ctrl-a x
      Only declared shares persist
      Writable store is tmpfs overlay
    Declarative Everything
      Single inventory.nix registry
      NixOS module composition
      Reproducible VM definitions
      Flake-pinned dependencies
    Zero-Copy Performance
      virtiofs shared filesystem
      Host Nix store reuse
      Sparse ephemeral volumes
      ~50ms volume setup per boot
    Multi-Agent
      N agents from one flake
      Per-agent credentials
      Per-agent persistent state
      Private per-VM workspace
```

---

## Security Model

Permafrost's security rests on nested isolation layers. Each layer restricts what the one inside it can access.

```mermaid
graph TB
    subgraph L1["Layer 1: Host OS"]
        direction TB
        L1_DESC["Full system access<br/>Only root can launch VMs"]

        subgraph L2["Layer 2: systemd Transient Unit"]
            L2_DESC["RuntimeDirectory scoping<br/>Auto-cleanup on exit<br/>Process containment"]

            subgraph L3A["Layer 3a: virtiofsd"]
                L3A_DESC["Namespace sandbox<br/>per shared directory<br/>Read-only for /nix/store"]
            end

            subgraph L3B["Layer 3b: KVM (cloud-hypervisor)"]
                L3B_DESC["Hardware isolation<br/>Rust-based VMM<br/>Minimal attack surface"]

                subgraph L4["Layer 4: Guest NixOS"]
                    L4_DESC["Unprivileged agent user<br/>tmpfs home (ephemeral)<br/>No host filesystem access<br/>except declared virtiofs shares"]
                end
            end
        end
    end

    style L1 fill:#d6282822,stroke:#d62828,stroke-width:3px
    style L2 fill:#f77f0022,stroke:#f77f00,stroke-width:2px
    style L3A fill:#4361ee22,stroke:#4361ee,stroke-width:2px
    style L3B fill:#7209b722,stroke:#7209b7,stroke-width:3px
    style L4 fill:#06d6a022,stroke:#06d6a0,stroke-width:2px
```

---

## Agent Spec Schema

Every agent is a declarative spec in `modules/inventory.nix`. The same spec drives both standalone runner scripts (`nix run`) and host-managed fleet deployment. To see all available agents, run `nix flake show`.

```mermaid
graph LR
    INV["inventory.nix"] --> SPEC

    subgraph SPEC["Agent Spec"]
        direction TB
        ID["name · ip · mac · vsockCid"]
        PKG["extraPackages<br/>(CLI tools, MCP servers)"]
        CRED["credentials<br/>(auto-injected API keys)"]
        SHARE["persistentShares<br/>(host ↔ guest mounts)"]
        GUI["gui<br/>(optional Wayland passthrough)"]
    end

    SPEC --> RUNNER["runners.nix<br/>mkRunner → nix run"]
    SPEC --> FLEET["agents.nix<br/>mkAgentVm → fleet deploy"]

    style INV fill:#f77f00,stroke:#d62828,color:#fff,stroke-width:3px
    style SPEC fill:#533483,color:#fff
    style RUNNER fill:#4361ee,color:#fff
    style FLEET fill:#7209b7,color:#fff
```

---

## What Happens When You Launch an Agent

```mermaid
sequenceDiagram
    participant U as User (sudo)
    participant R as Runner Script
    participant SD as systemd-run
    participant VFS as virtiofsd (x N)
    participant CHV as cloud-hypervisor
    participant G as Guest NixOS

    U->>R: sudo nix run .#claude
    activate R

    Note over R: 1. Detect SUDO_USER,<br/>REAL_HOME, Wayland socket

    R->>R: 2. JIT Network Setup
    Note over R: Create microbr bridge<br/>Add NAT/MASQUERADE rules<br/>Spawn background TAP attach

    R->>SD: 3. exec systemd-run --pty
    activate SD
    Note over SD: RuntimeDirectory=<br/>microvm-(name)<br/>(auto-cleanup on exit)

    SD->>VFS: 4. Launch virtiofsd backends
    activate VFS
    Note over VFS: One socket per share:<br/>ro-store (read-only Nix store)<br/>+ global share (.agents)<br/>+ per-agent persistentShares

    VFS-->>SD: Sockets ready

    SD->>CHV: 5. microvm-run
    activate CHV
    Note over CHV: Credentials injected as<br/>--platform oem_string=[<br/>io.systemd.credential:KEY=val]

    CHV->>G: 6. Boot guest kernel
    activate G
    Note over G: Mount virtiofs shares<br/>Mount ephemeral volumes<br/>Create overlay store<br/>swapon /dev/vdd<br/>Symlink persists<br/>Auto-login as agent

    G-->>U: 7. Interactive console

    U->>G: 8. Agent work happens here

    U->>CHV: 9. Ctrl-a x (terminate)
    deactivate G
    deactivate CHV
    deactivate VFS

    SD->>SD: 10. RuntimeDirectory cleaned
    Note over SD: All sockets, PIDs,<br/>temp mounts removed
    deactivate SD
    deactivate R
```

---

## Filesystem Architecture

The guest assembles its filesystem from three sources: the host's Nix store as a read-only
virtiofs lowerdir, explicitly declared virtiofs shares that persist, and per-VM disk images
that are destroyed and recreated on every boot.

Every writable path lives on one of those ephemeral volumes. Only `/` stays in RAM. This is
deliberate: they were previously tmpfs, which meant an 8 GiB VM held 32 GiB of unreachable
size caps and `nix run` failed with ENOSPC long before any declared limit.

| Volume | Mount | Filesystem | Size | Device |
|---|---|---|---|---|
| `rw-store.img` | `/nix/.rw-store` | ext4 | 32 GiB | `/dev/vda` |
| `home.img` | `/home/agent` | btrfs + zstd | 32 GiB | `/dev/vdb` |
| `tmp.img` | `/tmp` | ext4 | 16 GiB | `/dev/vdc` |
| `swap.img` | *(raw swap)* | — | 4 GiB | `/dev/vdd` |

Images live at `/var/lib/permafrost/<agent>/` and are sparse, so a booted VM occupies well
under 1 MiB and grows only as the agent writes. Setup costs about 50 ms per boot: `mkfs` on
a sparse image is 27–52 ms, and swap is initialised by writing only a header host-side
(`mkswap`, ~7 ms) rather than `dd`-ing 4 GiB through virtio-blk on every boot.

```mermaid
graph TD
    subgraph HOST_FS["Host Filesystem"]
        H_STORE["/nix/store<br/>(immutable)"]
        H_GLOBAL["~/.agents<br/>(global share)"]
        H_AGENT["~/per-agent paths<br/>(from persistentShares)"]
        H_IMG["/var/lib/permafrost/(agent)/*.img<br/>(sparse, wiped each boot)"]
    end

    subgraph VIRTIOFS["virtiofs (zero-copy)"]
        VF1["ro-store.sock<br/>(read-only)"]
        VF2["persist_*.sock<br/>(read-write)"]
    end

    subgraph GUEST_FS["Guest Filesystem"]
        subgraph NIX_UNION["Nix Store (overlay union)"]
            RO["/nix/.ro-store<br/>(virtiofs, read-only)"]
            RW["/nix/.rw-store<br/>(ext4 volume, ephemeral)"]
            UNION["/nix/store<br/>(combined view)"]
        end

        subgraph HOME["/home/agent (btrfs volume, ephemeral)"]
            SYMS["Symlinks into /mnt/persist/*<br/>for each declared share"]
            WS["workspace/<br/>(private per-VM, not shared)"]
            EPHEM["All other dotfiles and caches<br/>(destroyed on exit)"]
        end

        TMPV["/tmp<br/>(ext4 volume, ephemeral)"]
        SWAP["swap<br/>(raw volume, 4 GiB)"]
        PERSIST["/mnt/persist/*<br/>virtiofs mount points"]
    end

    H_STORE -->|virtiofs| VF1 --> RO
    H_GLOBAL -->|virtiofs| VF2 --> PERSIST
    H_AGENT -->|virtiofs| VF2
    H_IMG -->|virtio-blk| RW
    H_IMG -->|virtio-blk| HOME
    H_IMG -->|virtio-blk| TMPV
    H_IMG -->|virtio-blk| SWAP
    RO --> UNION
    RW --> UNION
    PERSIST --> SYMS

    style HOST_FS fill:#0f3460,stroke:#16213e,color:#fff
    style VIRTIOFS fill:#1a1a2e,stroke:#e94560,color:#fff,stroke-width:2px
    style GUEST_FS fill:#16213e22,stroke:#16213e
    style NIX_UNION fill:#4361ee22,stroke:#4361ee
    style HOME fill:#f7200522,stroke:#f72585
    style EPHEM fill:#d62828,color:#fff
    style UNION fill:#06d6a0,color:#000
```

---

## Secret Injection Pipeline

Secrets never enter the Nix store. They flow from encrypted storage through the host and into the guest as volatile OEM strings.

```mermaid
graph LR
    subgraph ENCRYPTED["At Rest (Encrypted)"]
        YAML["secrets/agents.yaml<br/>(sops-encrypted)"]
        TPM["TPM 2.0<br/>(hardware-bound<br/>age key)"]
    end

    subgraph HOST_DECRYPT["Host Decryption (boot)"]
        PREP["systemd oneshot:<br/>sops-age-key-prep"]
        AGE_KEY["/var/lib/sops-nix/<br/>key.txt"]
        SOPS_SVC["sops-nix.service"]
        RUN_SEC["/run/secrets/*"]
    end

    subgraph LAUNCH["VM Launch (runtime)"]
        CRED_FIX["microvm-credential-fix.nix<br/>extraArgsScript"]
        OEM["--platform oem_string=[<br/>io.systemd.credential:<br/>KEY=value, ...]"]
    end

    subgraph GUEST_CONSUME["Guest Consumption"]
        KERN["Guest kernel<br/>reads OEM strings"]
        SYSTEMD["systemd mounts to<br/>/run/host/credentials/"]
        AGENT["Agent process<br/>reads credential"]
    end

    TPM -->|"decrypt"| PREP
    PREP --> AGE_KEY
    AGE_KEY --> SOPS_SVC
    YAML --> SOPS_SVC
    SOPS_SVC --> RUN_SEC
    RUN_SEC -->|"cat at launch"| CRED_FIX
    CRED_FIX --> OEM
    OEM --> KERN
    KERN --> SYSTEMD
    SYSTEMD --> AGENT

    style ENCRYPTED fill:#d62828,color:#fff,stroke-width:3px
    style HOST_DECRYPT fill:#0f3460,color:#fff
    style LAUNCH fill:#7209b7,color:#fff
    style GUEST_CONSUME fill:#06d6a0,color:#000
```

---

## Further Reading

For deeper subsystem details — flake input graphs, module composition, network topology, overlay pipelines, and GUI passthrough internals:

- **[Architecture Deep Dive](docs/architecture.md)**: Extended diagrams and subsystem internals.
- **[Usage Guide](docs/usage.md)**: Running agents, managing environments, and Wayland/GUI passthrough.
- **[Technical Reference](docs/reference.md)**: `cloud-hypervisor` constraints, `tap` networking, and systemd-credential injection.
