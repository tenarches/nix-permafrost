{
  inputs,
  pkgs,
  ...
}:

let
  inherit (pkgs) lib;

  openclaude = pkgs.callPackage ./programs/openclaude.nix { };
  mcpServers = [
    pkgs.context7-mcp
    pkgs.mcp-server-time
    pkgs.github-mcp-server
    pkgs.terraform-mcp-server
    pkgs.mcp-nixos
  ];

  specs = {
    claude = {
      name = "claude";
      tapId = "claude";
      ip = "192.168.33.10";
      mac = "02:00:00:00:00:10";
      vsockCid = 10;
      workspacePath = "/run/agent-workspaces/claude";
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
      ];
      extraPackages = [
        inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.claude-code
        openclaude
      ]
      ++ mcpServers;
      credentials = {
        ANTHROPIC_API_KEY = "/run/secrets/anthropic-api-key";
      };
    };

    gemini = {
      name = "gemini";
      tapId = "gemini";
      ip = "192.168.33.11";
      mac = "02:00:00:00:00:11";
      vsockCid = 11;
      workspacePath = "/run/agent-workspaces/gemini";
      persistentShares = [
        {
          host = ".gemini";
          guest = ".gemini";
        }
      ];
      extraPackages = [
        inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.gemini-cli
      ]
      ++ mcpServers;
      credentials = {
        GOOGLE_API_KEY = "/run/secrets/google-api-key";
      };
    };

    opencode = {
      name = "opencode";
      tapId = "ocode";
      ip = "192.168.33.13";
      mac = "02:00:00:00:00:13";
      vsockCid = 13;
      workspacePath = "/run/agent-workspaces/opencode";
      persistentShares = [
        {
          host = ".config/opencode";
          guest = ".config/opencode";
        }
      ];
      extraPackages = [
        inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.opencode
      ]
      ++ mcpServers;
      credentials = {
        OPENAI_API_KEY = "/run/secrets/openai-api-key";
      };
    };

    pi = {
      name = "pi";
      tapId = "pi";
      ip = "192.168.33.14";
      mac = "02:00:00:00:00:14";
      vsockCid = 14;
      workspacePath = "/run/agent-workspaces/pi";
      persistentShares = [
        {
          host = ".pi";
          guest = ".pi";
        }
      ];
      extraPackages = [
        inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.pi
        inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.mcporter
      ]
      ++ mcpServers;
    };

    bv = {
      name = "bv";
      tapId = "bv";
      ip = "192.168.33.16";
      mac = "02:00:00:00:00:16";
      vsockCid = 16;
      workspacePath = "/run/agent-workspaces/bv";
      persistentShares = [
        # Pi auth — Gemini OAuth tokens (written by `pi /login`)
        {
          host = ".pi";
          guest = ".pi";
        }
        # Builder-verifier project tree: orchestrator, configs, sessions
        {
          host = "bv";
          guest = "bv";
        }
        # mcporter MCP server configuration
        {
          host = ".mcporter";
          guest = ".mcporter";
        }
      ];
      extraPackages = [
        inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.pi
        inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.mcporter
        pkgs.nodejs_22
        pkgs.tsx
      ]
      ++ mcpServers;
      credentials = {
        GITHUB_TOKEN = "/run/secrets/github-token";
      };
      env = {
        LLAMA_CPP_ENDPOINT = "http://dualie.home.lan:8001";
        PI_CODING_AGENT_SESSION_DIR = "/home/agent/bv/sessions";
      };

      homeFiles = {
        ".mcporter/mcporter.json".text = builtins.toJSON {
          mcpServers = {
            context7 = {
              command = "context7-mcp";
              args = [ ];
            };
            github = {
              command = "github-mcp-server";
              args = [ ];
              env = {
                GITHUB_PERSONAL_ACCESS_TOKEN = "\${GITHUB_TOKEN}";
              };
            };
            nixos = {
              command = "mcp-nixos";
              args = [ ];
            };
            time = {
              command = "mcp-server-time";
              args = [ ];
            };
          };
        };

        ".pi/agent/models.json".text = builtins.toJSON {
          providers = {
            llama-cpp-local = {
              name = "llama-cpp (dualie)";
              baseUrl = "http://dualie.home.lan:8001/v1";
              apiKey = "not-required";
              api = "openai-completions";
              compat = {
                supportsDeveloperRole = false;
                supportsReasoningEffort = false;
              };
              models = [
                {
                  id = "qwen3.6-35b-a3b-coding-agent-64k";
                  name = "Qwen 3.6 35B Verifier (64k)";
                }
                {
                  id = "qwen3.6-verifier-128k";
                  name = "Qwen 3.6 35B Verifier (128k)";
                }
              ];
            };
          };
        };

        "bv/verifier/extensions/verifier-provider.ts".text = ''
          import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";

          export default function (pi: ExtensionAPI) {
            pi.registerProvider("llama-cpp-local", {
              name: "llama-cpp (dualie)",
              baseUrl: "http://dualie.home.lan:8001/v1",
              apiKey: "not-required",
              api: "openai-completions",

              compat: {
                supportsDeveloperRole = false,
                supportsReasoningEffort = false,
              },

              models: [
                {
                  id = "qwen3.6-35b-a3b-coding-agent-64k";
                  name = "Qwen 3.6 35B Verifier (64k)",
                  contextWindow = 65536,
                  input: ["text"],
                  reasoning: false,
                },
                {
                  id = "qwen3.6-verifier-128k",
                  name = "Qwen 3.6 35B Verifier (128k)",
                  contextWindow = 131072,
                  input: ["text"],
                  reasoning: false,
                },
              ],
            });
          }
        '';

        "bv/orchestrator/package.json".text = builtins.toJSON {
          name = "bv-orchestrator";
          version = "1.0.0";
          type = "module";
          scripts = {
            start = "node --import tsx orchestrator.ts";
          };
          dependencies = {
            "@mariozechner/pi-coding-agent" = "*";
          };
        };

        "bv/orchestrator/tsconfig.json".text = builtins.toJSON {
          compilerOptions = {
            target = "ESNext";
            module = "ESNext";
            moduleResolution = "Bundler";
            esModuleInterop = true;
            skipLibCheck = true;
            strict = true;
          };
        };

        "bv/notify.json".text = builtins.toJSON {
          webhookUrl = "http://replace-with-actual-webhook-url";
          commandListenerEnabled = true;
          commandListenerPort = 9876;
        };

        "bv/builder/.pi/settings.json".text = builtins.toJSON {
          session = {
            dir = "/home/agent/bv/sessions";
          };
        };

        "bv/orchestrator/orchestrator.ts".text = ''
          import {
            AuthStorage,
            createAgentSession,
            ModelRegistry,
            SessionManager,
          } from "@mariozechner/pi-coding-agent";
          import { readdir, readFile } from "fs/promises";
          import { join } from "path";
          import crypto from "crypto";
          import { NotificationBus } from "./notify.js";
          import { CommandListener } from "./command-listener.js";
          import { loadNotifyConfig } from "./notify-config.js";

          // ─── Constants ────────────────────────────────────────────────────────────────

          const HOME = process.env.HOME ?? "/home/agent";
          const BV_DIR = join(HOME, "bv");
          const BUILDER_CWD = join(BV_DIR, "builder");
          const VERIFIER_CWD = join(BV_DIR, "verifier");
          const SESSIONS_DIR = join(BV_DIR, "sessions");

          const BUILDER_MODEL = "gemini-2.5-pro-preview-06-05";
          const VERIFIER_MODEL_64K = "qwen3.6-35b-a3b-coding-agent-64k";
          const VERIFIER_MODEL_128K = "qwen3.6-verifier-128k";

          const MAX_RETRIES = 2;
          const TIER2_CHAR_THRESHOLD = 200_000; // ~50k tokens at 4 chars/token

          // ─── Types ────────────────────────────────────────────────────────────────────

          interface VerifierReport {
            status: "PASSED" | "FAILED";
            confidence: "HIGH" | "FEEDBACK" | "UNCERTAIN";
            report: {
              total_claims: number;
              verified: number;
              failed: number;
              unverified: number;
              policy_violations: Array<{ rule: string; evidence: string }>;
              claim_results: Array<{
                claim: string;
                status: "VERIFIED" | "FAILED" | "UNVERIFIED";
                evidence: string;
                note?: string;
              }>;
              what_could_not_be_verified: string;
              feedback_for_builder?: string;
            };
          }

          // ─── Orchestrator ─────────────────────────────────────────────────────────────

          export class Orchestrator {
            private task: string;
            private retryCount = 0;
            private lastReport: VerifierReport | null = null;
            private builderSession: any = null;
            private bus: NotificationBus;
            private commandListener: CommandListener | null = null;
            private abortRequested = false;

            constructor(task: string) {
              this.task = task;
              const sessionId = crypto.randomUUID();
              this.bus = new NotificationBus(sessionId);

              const config = loadNotifyConfig();
              if (config.commandListenerEnabled) {
                this.commandListener = new CommandListener(this.bus, config);
              }
            }

            async run(): Promise<void> {
              this.commandListener?.start();
              this.bus.emit("INIT", "session.started", `Task session started`, {
                task_preview: this.task.slice(0, 120),
              });

              try {
                await this.init();
                await this.build();
                await this.lint();
                await this.verify();
              } catch (err) {
                await this.escalate(`Uncaught error: $\{err}`);
              } finally {
                this.commandListener?.stop();
                this.bus.emit("INIT", "session.ended", "Session ended");
              }
            }

            // ── INIT ──────────────────────────────────────────────────────────────────

            private async init(): Promise<void> {
              this.bus.emit("INIT", "session.started", "Creating builder session");

              const authStorage = AuthStorage.create();
              const modelRegistry = ModelRegistry.create(authStorage);

              const { session } = await createAgentSession({
                sessionManager: SessionManager.fromDirectory(SESSIONS_DIR),
                authStorage,
                modelRegistry,
                model: BUILDER_MODEL,
                cwd: BUILDER_CWD,
                extensionDirs: [join(BUILDER_CWD, "extensions")],
                settingsDir: join(BUILDER_CWD, ".pi"),
              });

              this.builderSession = session;
              this.attachObserver(session, "BUILDER");

              // Prime the builder before the task begins.
              this.bus.emit("INIT", "build.started", "Running prime skill");
              await this.builderSession.prompt("/skill:prime");
            }

            private attachObserver(session: any, label: string): void {
              const onEvent = (event: any) => {
                if (!event) return;
                if (event.type === "message_update") {
                  const ae = event.assistantMessageEvent;
                  if (!ae) return;
                  if (ae.type === "tool_call") {
                    this.bus.emit("BUILD", "build.tool_call", `Tool call: $\{ae.name}`, { tool: ae.name, input: ae.input });
                  }
                }
              };
              if (typeof session.on === "function") {
                session.on("event", onEvent);
              } else if (session.events && typeof session.events.on === "function") {
                session.events.on("data", onEvent);
              }
            }

            // ── BUILD ─────────────────────────────────────────────────────────────────

            private async build(feedbackPrompt?: string): Promise<void> {
              if (this.abortRequested) await this.escalate("Abort requested by user.");

              const label = feedbackPrompt
                ? `retry $\{this.retryCount}/$\{MAX_RETRIES}`
                : "initial";
              this.bus.emit("BUILD", "build.started", `Starting build phase ($\{label})`);

              const prompt = feedbackPrompt
                ? `VERIFIER FEEDBACK (attempt $\{this.retryCount}/$\{MAX_RETRIES}):\n\n$\{feedbackPrompt}\n\nAddress all feedback. Provide an updated COMPLETION SUMMARY.`
                : this.task;

              await this.builderSession.prompt(prompt);
              this.bus.emit("BUILD", "build.completed", "Builder turn complete");
            }

            // ── LINT ─────────────────────────────────────────────────────────────────

            private async lint(): Promise<void> {
              this.bus.emit("LINT", "lint.started", "Running deterministic checks");

              const { execFile } = await import("child_process");
              const { promisify } = await import("util");
              const exec = promisify(execFile);

              const projectCwd = join(HOME, "workspace");
              const checks = [
                { name: "tsc", cmd: "npx", args: ["tsc", "--noEmit"] },
                { name: "eslint", cmd: "npx", args: ["eslint", "src/", "--max-warnings", "0"] },
              ];

              const failed: string[] = [];
              for (const check of checks) {
                try {
                  await exec(check.cmd, check.args, { cwd: projectCwd });
                } catch {
                  failed.push(check.name);
                }
              }

              if (failed.length === 0) {
                this.bus.emit("LINT", "lint.passed", "All lint checks passed");
                return;
              }

              this.bus.emit("LINT", "lint.failed", `Lint failed: $\{failed.join(", ")}`, { failed });

              if (this.retryCount >= MAX_RETRIES) {
                await this.escalate(`Lint loop hit max retries. Failing: $\{failed.join(", ")}`);
                return;
              }

              this.retryCount++;
              this.bus.setRetryCount(this.retryCount);
              const feedback = `LINT FAILURE:\n$\{failed.map((f) => `- $\{f} check failed`).join("\n")}\n\nFix all lint errors before resubmitting.`;
              await this.build(feedback);
              await this.lint();
            }

            // ── VERIFY ────────────────────────────────────────────────────────────────

            private async verify(): Promise<void> {
              this.bus.emit("VERIFY", "verify.started", "Starting verification phase");

              const sessionContent = await this.readLatestBuilderSession();
              const verifierModel =
                sessionContent.length >= TIER2_CHAR_THRESHOLD
                  ? VERIFIER_MODEL_128K
                  : VERIFIER_MODEL_64K;

              this.bus.emit("VERIFY", "verify.started", `Session $\{sessionContent.length} chars → $\{verifierModel}`);

              const report = await this.runVerifier(sessionContent, verifierModel);
              this.lastReport = report;

              if (report.status === "PASSED") {
                this.bus.emit("VERIFY", "verify.passed", `PASSED — $\{report.report.verified}/$\{report.report.total_claims} claims verified`);
                this.done();
                return;
              }

              this.bus.emit("VERIFY", "verify.failed", `FAILED — $\{report.report.failed} failed, $\{report.report.unverified} unverified`, { report: report.report });

              if (this.retryCount >= MAX_RETRIES) {
                await this.escalate(
                  `Verifier failed after $\{MAX_RETRIES} retries:\n$\{JSON.stringify(report.report, null, 2)}`
                );
                return;
              }

              this.retryCount++;
              this.bus.setRetryCount(this.retryCount);
              await this.build(report.report.feedback_for_builder ?? "Verification failed.");
              await this.lint();
              await this.verify();
            }

            // ── DONE / ESCALATE ───────────────────────────────────────────────────────

            private done(): void {
              this.bus.emit("DONE", "task.completed", "Task verified. Ready for PR.");
              process.stdout.write(JSON.stringify({ status: "DONE", report: this.lastReport }) + "\n");
            }

            private async escalate(reason: string): Promise<never> {
              this.bus.emit("ESCALATE", "task.escalated", reason, { retries: this.retryCount }, "error");
              process.exit(1);
            }

            // ── Helpers ───────────────────────────────────────────────────────────────

            private async readLatestBuilderSession(): Promise<string> {
              const files = (await readdir(SESSIONS_DIR))
                .filter((f) => f.endsWith(".jsonl"))
                .sort();
              if (files.length === 0) throw new Error(`No session files in $\{SESSIONS_DIR}`);
              return readFile(join(SESSIONS_DIR, files[files.length - 1]), "utf-8");
            }

            private async runVerifier(sessionContent: string, model: string): Promise<VerifierReport> {
              const authStorage = AuthStorage.create();
              const modelRegistry = ModelRegistry.create(authStorage);

              const { session } = await createAgentSession({
                sessionManager: SessionManager.inMemory(),
                authStorage,
                modelRegistry,
                model,
                cwd: VERIFIER_CWD,
                extensionDirs: [join(VERIFIER_CWD, "extensions")],
                settingsDir: join(VERIFIER_CWD, ".pi"),
              });

              const prompt = [
                "BUILDER SESSION LOG (JSONL):",
                sessionContent,
                "---",
                "VERIFICATION TASK:",
                `Original task: $\{this.task}`,
                "",
                "Audit the session log. Return only the JSON report as specified in your instructions.",
              ].join("\n");

              await session.prompt(prompt);
              const raw = await session.getLastAssistantText?.() ?? "";
              return this.parseReport(raw);
            }

            private parseReport(raw: string): VerifierReport {
              const cleaned = raw.replace(/^```json\s*/m, "").replace(/\s*```$/m, "").trim();
              try {
                return JSON.parse(cleaned) as VerifierReport;
              } catch {
                return {
                  status: "FAILED",
                  confidence: "UNCERTAIN",
                  report: {
                    total_claims: 0,
                    verified: 0,
                    failed: 0,
                    unverified: 0,
                    policy_violations: [],
                    claim_results: [],
                    what_could_not_be_verified: "Verifier response was not valid JSON",
                    feedback_for_builder: "Verifier output could not be parsed. Human review required.",
                  },
                };
              }
            }
          }

          // ─── Entry Point ──────────────────────────────────────────────────────────────

          const args = process.argv.slice(2);
          const taskIdx = args.indexOf("--task");
          if (taskIdx === -1 || !args[taskIdx + 1]) {
            console.error("Usage: node orchestrator.js --task <description>");
            process.exit(1);
          }

          new Orchestrator(args[taskIdx + 1]).run().catch((err) => {
            console.error("Fatal:", err);
            process.exit(1);
          });
        '';

        "bv/orchestrator/notify.ts".text = ''
          import crypto from "crypto";
          import { NotifyConfig, loadNotifyConfig } from "./notify-config.js";

          export type NotificationStage = "INIT" | "BUILD" | "LINT" | "VERIFY" | "DONE" | "ESCALATE";
          export type NotificationEventType =
            | "session.started" | "session.ended"
            | "build.started" | "build.completed" | "build.tool_call" | "build.tool_error"
            | "lint.started" | "lint.passed" | "lint.failed"
            | "verify.started" | "verify.passed" | "verify.failed" | "verify.uncertain"
            | "feedback.sent" | "task.completed" | "task.escalated"
            | "command.received" | "command.rejected";
          export type NotificationLevel = "info" | "warn" | "error";

          export interface NotificationEvent {
            id: string;
            session_id: string;
            timestamp: string;
            stage: NotificationStage;
            type: NotificationEventType;
            level: NotificationLevel;
            message: string;
            retry_count: number;
            payload?: Record<string, unknown>;
          }

          export class NotificationBus {
            private sessionId: string;
            private retryCount = 0;
            private config: NotifyConfig;
            private commandQueue: any[] = [];

            constructor(sessionId: string) {
              this.sessionId = sessionId;
              this.config = loadNotifyConfig();
            }

            setRetryCount(n: number): void { this.retryCount = n; }

            emit(stage: NotificationStage, type: NotificationEventType, message: string, payload?: Record<string, unknown>, level: NotificationLevel = "info"): void {
              const event: NotificationEvent = {
                id: crypto.randomUUID(),
                session_id: this.sessionId,
                timestamp: new Date().toISOString(),
                stage, type, level, message,
                retry_count: this.retryCount,
                payload,
              };
              process.stderr.write(`[$\{event.timestamp}] [$\{stage}] [$\{type}] $\{message}\n`);
              if (this.config.webhookUrl) {
                this.fireWebhook(event).catch(() => {});
              }
            }

            enqueueCommand(cmd: any): void { this.commandQueue.push(cmd); }

            private async fireWebhook(event: NotificationEvent): Promise<void> {
              // Implementation details simplified for Nix string inclusion
              await fetch(this.config.webhookUrl!, {
                method: "POST",
                headers: { "Content-Type": "application/json" },
                body: JSON.stringify(event),
              });
            }
          }
        '';

        "bv/orchestrator/notify-config.ts".text = ''
          import { readFileSync, existsSync } from "fs";
          import { homedir } from "os";
          import { join } from "path";

          export interface NotifyConfig {
            webhookUrl?: string;
            commandListenerEnabled?: boolean;
            commandListenerPort?: number;
          }

          export function loadNotifyConfig(): NotifyConfig {
            const path = join(process.env.HOME ?? homedir(), "bv", "notify.json");
            if (existsSync(path)) {
              try { return JSON.parse(readFileSync(path, "utf-8")); } catch { return {}; }
            }
            return {};
          }
        '';

        "bv/orchestrator/command-listener.ts".text = ''
          import { createServer } from "http";
          import { NotificationBus } from "./notify.js";
          import { NotifyConfig } from "./notify-config.js";

          export class CommandListener {
            private server: any;
            private bus: NotificationBus;
            private config: NotifyConfig;

            constructor(bus: NotificationBus, config: NotifyConfig) {
              this.bus = bus;
              this.config = config;
              this.server = createServer((req, res) => {
                res.writeHead(200);
                res.end("OK");
              });
            }

            start(): void {
              const port = this.config.commandListenerPort ?? 9876;
              this.server.listen(port, "0.0.0.0");
            }

            stop(): void { this.server.close(); }
          }
        '';

        "bv/builder/AGENTS.md".text = ''
          # Builder Agent — Operating Instructions

          ## Role
          You are a code generation agent. Your output will be audited by a verification
          agent that reads your complete session log and validates every claim you make
          against your actual tool outputs.

          ## Prime Protocol
          Before any task, run `/skill:prime` to load codebase context. Do not skip this.

          ## Completion Standards
          - Every claim must be verifiable from tool outputs in this session.
          - If you run a test, include the exact command and output.
          - If you create a file, state its path, approximate size, and purpose.
          - If a bash command exits non-zero, report it — do not proceed as if it succeeded.
          - Never assert success without a corresponding tool result as evidence.

          ## Output Format
          End every response with a structured completion summary:

          ```
          ## COMPLETION SUMMARY
          - Files created: [path, purpose]
          - Files modified: [path, what changed]
          - Commands run: [command, exit code]
          - Tests passing: [count / total, or N/A]
          - Atomic claims:
            1. File src/auth/token.ts exists, ~142 bytes
            2. npm test exited 0, output: 14 passed 0 failed
            3. [...]
          ```
        '';

        "bv/builder/extensions/bash-lockdown.ts".text = ''
          const ALLOWED: Set<string> = new Set([
            "ls", "cat", "head", "tail", "wc", "stat", "file",
            "grep", "find", "rg", "git", "node", "npm", "npx", "pnpm",
            "tsc", "eslint", "prettier", "jest", "vitest", "mocha",
            "echo", "printf", "test", "true", "false", "pwd",
            "mkdir", "cp", "mv", "touch",
          ]);

          export default function load(pi: any) {
            pi.on("tool_call", async (event: any) => {
              if (event.tool !== "bash") return undefined;
              const tokens = (event.input?.command ?? "").trim().split(/\s+/);
              const base = tokens[0];
              if (!ALLOWED.has(base)) {
                return { error: `SECURITY: '$\{base}' not in bash allowlist.` };
              }
              return undefined;
            });
          }
        '';

        "bv/builder/skills/prime.md".text = ''
          ---
          description: "Load essential codebase context before starting any implementation task."
          ---
          # Skill: prime
          1. Read AGENTS.md
          2. Read package.json
          3. Run ls -la
          4. Read README.md
        '';

        "bv/builder/skills/mcporter.md".text = ''
          ---
          description: "Call MCP servers via the mcporter CLI."
          ---
          # Skill: mcporter
          Use `npx mcporter call <server>.<tool> key:value` to integrate with GitHub, Jira, etc.
        '';

        "bv/verifier/AGENTS.md".text = ''
          # Verifier Agent — Operating Instructions

          ## Role
          You are a verification agent. You audit the session log of a builder agent.

          ## Verification Process
          1. Extract Atomic Claims from the builder's summary.
          2. Verify Each Claim against `bashExecution` or `tool_result` entries.
          3. Return ONLY the JSON report.

          ## Output Format
          {
            "status": "PASSED" | "FAILED",
            "report": { ... }
          }
        '';

        "bv/verifier/extensions/readonly-enforcer.ts".text = ''
          const BLOCKED = new Set(["write", "edit", "bash"]);
          export default function load(pi: any) {
            pi.on("tool_call", async (event: any) => {
              if (BLOCKED.has(event.tool)) {
                return { error: `Verifier: '$\{event.tool}' is disabled.` };
              }
              return undefined;
            });
          }
        '';
      };
    };

    antigravity = {
      name = "antigravity";
      tapId = "agrav";
      ip = "192.168.33.12";
      mac = "02:00:00:00:00:12";
      vsockCid = 12;
      workspacePath = "/run/agent-workspaces/antigravity";
      persistentShares = [
        {
          host = ".gemini";
          guest = ".gemini";
        }
      ];
      gui = true;
      extraPackages = [ pkgs.antigravity ];
    };

    crush = {
      name = "crush";
      tapId = "crush";
      ip = "192.168.33.15";
      mac = "02:00:00:00:00:15";
      vsockCid = 15;
      workspacePath = "/run/agent-workspaces/crush";
      persistentShares = [
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
        inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.crush
      ];
    };
  };

  allSpecs = lib.attrValues specs;
  allTapIds = map (s: s.tapId) allSpecs;
  allCids = map (s: s.vsockCid) allSpecs;

in

assert lib.assertMsg (builtins.all (id: builtins.stringLength id <= 7) allTapIds)
  "inventory: one or more tapId values exceed 7 characters (max for IFNAMSIZ with 'microvm-' prefix)";

assert lib.assertMsg (
  builtins.length allTapIds == builtins.length (lib.unique allTapIds)
) "inventory: duplicate tapId detected — each agent must have a unique tapId";

assert lib.assertMsg (
  builtins.length allCids == builtins.length (lib.unique allCids)
) "inventory: duplicate vsockCid detected — each agent must have a unique vsockCid";

specs
