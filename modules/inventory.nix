{ inputs, pkgs, ... }:

let
  inherit (pkgs) lib;

  inherit (pkgs.stdenv.hostPlatform) system;
  agents = inputs.llm-agents.packages.${system};

  models = import ./models.nix { inherit pkgs lib; };

  openclaude = pkgs.callPackage ./programs/openclaude.nix { };
  mcpServers = [
    pkgs.context7-mcp
    pkgs.mcp-server-time
    pkgs.github-mcp-server
    pkgs.terraform-mcp-server
    pkgs.mcp-nixos
  ];

  # Browser automation.
  #
  # playwright-test, not playwright: the latter is playwright-core, a bare node
  # library directory with no bin/, so installing it puts nothing on PATH. This
  # is the package that carries the `playwright` command, and its wrapper
  # defaults PLAYWRIGHT_BROWSERS_PATH to the Nix-built browsers — which matters
  # here, because the fallback is upstream's own download: an unpatched binary
  # that will not run on NixOS, fetched into a home that is discarded at
  # shutdown anyway.
  #
  # The browsers are ~2.1GiB, but /nix/store reaches the guest over virtiofs
  # from the host, so that is one copy on the host either way.
  browserTools = [ pkgs.playwright-test ];

  # One guest, every harness.
  #
  # This used to be seven specs, one microvm each. They diverged in almost
  # nothing — the same MCP servers, the same agent-base.nix, the same user and
  # the same network shape — so the split cost 8 GiB and a boot per agent while
  # buying no isolation that mattered. The boundary that does the work is
  # guest-vs-host, not agent-vs-agent, and that one is untouched by putting them
  # together.
  #
  # A consequence worth stating: the harnesses now share a home volume, so a
  # tree one of them checked out is visible to the others. That is the point.
  specs.permafrost = {
    name = "permafrost";
    # 'microvm-' + tapId must fit IFNAMSIZ, so this cannot be the hostname.
    tapId = "pf";
    ip = "192.168.33.10";
    mac = "02:00:00:00:00:10";
    vsockCid = 10;

    # The guest can display GUI apps on the host through waypipe without this:
    # `waypipe ssh agent@192.168.33.10 bash -l` needs nothing from the flag.
    #
    # `gui = true` additionally enables microvm.graphics — the in-guest
    # wayland-proxy plus a host-side crosvm virtio-gpu device — which buys you
    # "ssh in first, then launch anything" and Xwayland for X11 clients. It is
    # off because that path is upstream-fragile: it needs a Spectrum-patched
    # cloud-hypervisor pinned to 51.0, a crosvm pinned to an older vhost-user
    # dialect, and a Mesa kept on crosvm's own glibc generation (see flake.nix
    # and runners.nix). Turning it on also means building cloud-hypervisor from
    # source and having a live compositor in the launching session — see the
    # preflight check in runners.nix.
    gui = false;

    # Host dot directories, mapped in so an agent's auth and history survive a
    # boot of a guest that is otherwise wiped every time.
    #
    # ~/workspace is deliberately absent: the guest gets a private ephemeral
    # workspace on its own home volume (agent-base.nix), so nothing an agent
    # produces reaches the host unless it is pushed somewhere.
    #
    # ~/.dsh is deliberately absent too, for the opposite reason — see the
    # header of modules/dsh.nix. Its whole configuration is generated from Nix
    # and copied into the ephemeral home on every boot, so there is nothing to
    # carry across and nothing to keep in sync with a host dotfile.
    persistentShares = [
      {
        host = ".claude";
        guest = ".claude";
      }
      {
        host = ".config/claude";
        guest = ".claude-config";
        guestLink = ".claude.json";
      }
      {
        host = ".config/opencode";
        guest = ".config/opencode";
      }
      {
        host = ".pi";
        guest = ".pi";
      }
      {
        host = ".mcporter";
        guest = ".mcporter";
      }
      {
        host = ".config/crush";
        guest = ".config/crush";
      }
      {
        host = ".local/share/crush";
        guest = ".local/share/crush";
      }
    ];

    extraPackages = [
      agents.claude-code
      openclaude
      agents.opencode
      agents.pi
      agents.mcporter
      agents.crush
      agents.dsh
      pkgs.antigravity-cli
      # `dsh plugin ... add <pkg>` forwards to pnpm, which has to be on PATH for
      # optional bundles (the subagent-codex and subagent-claude-code providers,
      # a third-party TUI) to be installable at all.
      pkgs.pnpm
      # dsh-model edits the patch file in place.
      pkgs.yq-go
    ]
    ++ mcpServers
    ++ browserTools;

    homeFiles = {
      ".pi/agent/models.json".source = models.piModelsJson;
    };

    extraModules = [
      { _module.args.guestIp = "192.168.33.10"; }
      ./dsh.nix
    ];

    env = {
      # The microvm is the isolation boundary, so dsh's own sandbox is off and
      # nothing prompts for approval. bwrap is deliberately absent for the same
      # reason.
      DSH_PERMISSION_MODE = "danger-full-access";

      # Telemetry is off by default, but this also suppresses the anonymous user
      # id that would otherwise be stamped on every provider request — including
      # the ones going to our own endpoint. Any non-empty value is an
      # authoritative opt-out.
      DSH_TELEMETRY_DISABLED = "1";

      # The endpoint wants no key, but the adapter still resolves the variable
      # named by apiKeyEnv and errors when it is unset.
      VLLM_API_KEY = "not-required";
    };

    # Inert. Nothing reads this today: modules/agents.nix has
    # microvm.credentialFiles commented out and runners.nix never looks at the
    # field, so the OEM-string injection in agent-base.nix is never fed. Kept
    # because it records which keys the harnesses would want if it were wired.
    credentials = {
      ANTHROPIC_API_KEY = "/run/secrets/anthropic-api-key";
      OPENAI_API_KEY = "/run/secrets/openai-api-key";
    };
  };

in
assert lib.assertMsg (
  builtins.stringLength specs.permafrost.tapId <= 7
) "inventory: tapId exceeds 7 characters (max for IFNAMSIZ with the 'microvm-' prefix)";

specs
