import {
  AuthStorage,
  createAgentSession,
  ModelRegistry,
  SessionManager,
} from "@earendil-works/pi-coding-agent";
import { readdir, readFile, access } from "fs/promises";
import { join } from "path";
import { execFile } from "child_process";
import { promisify } from "util";
import crypto from "crypto";
import { NotificationBus } from "./notify.js";
import { CommandListener, type IncomingCommand } from "./command-listener.js";
import { loadNotifyConfig } from "./notify-config.js";

const execFileAsync = promisify(execFile);

// ─── Constants ────────────────────────────────────────────────────────────────

const HOME = process.env.HOME ?? "/home/agent";
const LOGIC_DIR = join(HOME, ".bv-logic");
const DATA_DIR = join(HOME, "bv");
const WORKSPACE_DIR = process.env.BV_PROJECT_ROOT ?? join(HOME, "workspace");

const BUILDER_CWD = join(LOGIC_DIR, "builder");
const VERIFIER_CWD = join(LOGIC_DIR, "verifier");
const SESSIONS_DIR = join(DATA_DIR, "sessions");

const BUILDER_MODEL = "gemini-2.5-pro-preview-06-05";
const VERIFIER_MODEL_64K = "qwen3.6-35b-a3b-coding-agent-mtp-128k";
const VERIFIER_MODEL_128K = "qwen3.6-35b-a3b-coding-agent-mtp-128k";

const MAX_RETRIES = 2;
const TIER2_CHAR_THRESHOLD = 200_000;

// ─── Types ────────────────────────────────────────────────────────────────────

interface TaskSpec {
  projectType: "greenfield" | "existing";
  task: string;
  scope: { include: string[]; exclude: string[] };
  branch?: string;
  techStack?: string;
  targetStructure?: string;
  context?: string;
  acceptanceCriteria: string[];
}

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

interface TextCollector {
  text: string;
}

function truncateSession(content: string, maxChars: number): string {
  if (content.length <= maxChars) return content;

  const lines = content.split("\n").filter((l) => l.trim());
  const priority: string[] = [];
  const rest: string[] = [];

  for (const line of lines) {
    let isPriority = false;
    try {
      const entry = JSON.parse(line);
      if (entry.type === "bashExecution") isPriority = true;
      if (entry.type === "tool_result" && (entry.name === "write" || entry.name === "edit")) isPriority = true;
    } catch {
      // non-JSON line, treat as non-priority
    }
    if (isPriority) {
      priority.push(line);
    } else {
      rest.push(line);
    }
  }

  // Last entry is always kept first (completion summary)
  const lastEntry = lines[lines.length - 1];
  let budget = maxChars;
  const kept: string[] = [];

  if (lastEntry) {
    kept.push(lastEntry);
    budget -= lastEntry.length + 1;
    // Remove from whichever list it landed in so it isn't added twice
    const pIdx = priority.lastIndexOf(lastEntry);
    if (pIdx !== -1) priority.splice(pIdx, 1);
    const rIdx = rest.lastIndexOf(lastEntry);
    if (rIdx !== -1) rest.splice(rIdx, 1);
  }

  // Priority entries next (collected forward, then prepended to preserve order)
  const priorityKept: string[] = [];
  for (const line of priority) {
    if (budget - line.length - 1 < 0) break;
    priorityKept.push(line);
    budget -= line.length + 1;
  }
  kept.unshift(...priorityKept);

  // Fill remaining budget with non-priority entries, newest first
  const filling: string[] = [];
  for (let i = rest.length - 1; i >= 0; i--) {
    if (budget - rest[i].length - 1 < 0) break;
    filling.push(rest[i]);
    budget -= rest[i].length + 1;
  }
  filling.reverse();
  kept.unshift(...filling);

  return kept.join("\n");
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
  private pauseRequested = false;
  private pendingInjects: string[] = [];

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
      await this.escalate(`Uncaught error: ${err}`);
    } finally {
      this.commandListener?.stop();
      this.bus.emit("INIT", "session.ended", "Session ended");
    }
  }

  private async init(): Promise<void> {
    this.bus.emit("INIT", "session.started", "Creating builder session");

    const authStorage = AuthStorage.create();
    const modelRegistry = ModelRegistry.create(authStorage);

    const builderModel = modelRegistry.find("google-generative-ai", BUILDER_MODEL);
    if (!builderModel) throw new Error(`Model not found: ${BUILDER_MODEL}`);

    const { session } = await createAgentSession({
      sessionManager: SessionManager.create(WORKSPACE_DIR, SESSIONS_DIR),
      authStorage,
      modelRegistry,
      model: builderModel,
      cwd: WORKSPACE_DIR,
      agentDir: BUILDER_CWD,
    });

    this.builderSession = session;
    this.attachObserver(session, "BUILDER");

    this.bus.emit("INIT", "build.started", "Running prime skill");
    await this.builderSession.prompt("/skill:prime");
  }

  private attachObserver(session: any, label: string): TextCollector {
    const collector: TextCollector = { text: "" };
    const onEvent = (event: any) => {
      if (!event) return;
      switch (event.type) {
        case "message_update": {
          const ae = event.assistantMessageEvent;
          if (!ae) return;
          if (ae.type === "text_delta") {
            collector.text += ae.delta;
            process.stderr.write(`[${label}] ${ae.delta}`);
          } else if (ae.type === "thinking_delta") {
            process.stderr.write(`[${label}:think] ${ae.delta}`);
          } else if (ae.type === "tool_call") {
            this.bus.emit("BUILD", "build.tool_call", `Tool call: ${ae.name}`, { tool: ae.name, input: ae.input });
            process.stderr.write(`\n[${label}] → ${ae.name}(${JSON.stringify(ae.input ?? {})})\n`);
          } else if (ae.type === "tool_result") {
            const out = String(ae.result ?? "").slice(0, 200);
            process.stderr.write(`[${label}] ← ${ae.name}: ${out}\n`);
          }
          break;
        }
        case "session_shutdown":
          process.stderr.write(`\n[${label}] session shutdown\n`);
          break;
      }
    };
    if (typeof session.on === "function") {
      session.on("event", onEvent);
    } else if (session.events && typeof session.events.on === "function") {
      session.events.on("data", onEvent);
    }
    return collector;
  }

  private async build(feedbackPrompt?: string): Promise<void> {
    if (this.abortRequested) await this.escalate("Abort requested by user.");

    const injected = this.pendingInjects.splice(0).join("\n\n");
    const label = feedbackPrompt
      ? `retry ${this.retryCount}/${MAX_RETRIES}`
      : "initial";
    this.bus.emit("BUILD", "build.started", `Starting build phase (${label})`);

    const basePrompt = feedbackPrompt
      ? `VERIFIER FEEDBACK (attempt ${this.retryCount}/${MAX_RETRIES}):\n\n${feedbackPrompt}\n\nAddress all feedback. Provide an updated COMPLETION SUMMARY.`
      : this.task;
    const prompt = injected ? `${injected}\n\n---\n\n${basePrompt}` : basePrompt;

    await this.builderSession.prompt(prompt);
    this.bus.emit("BUILD", "build.completed", "Builder turn complete");
    await this.drainCommands();
  }

  private async lint(): Promise<void> {
    this.bus.emit("LINT", "lint.started", "Running deterministic checks");
    const projectCwd = join(HOME, "workspace");

    const checks: Array<{ name: string; cmd: string; args: string[]; guard: string }> = [
      { name: "tsc", cmd: "npx", args: ["tsc", "--noEmit"], guard: "tsconfig.json" },
      { name: "eslint", cmd: "npx", args: ["eslint", "src/", "--max-warnings", "0"], guard: ".eslintrc" },
    ];

    const failed: Array<{ name: string; output: string }> = [];
    for (const check of checks) {
      try {
        await access(join(projectCwd, check.guard));
      } catch {
        continue;
      }
      try {
        await execFileAsync(check.cmd, check.args, { cwd: projectCwd, timeout: 120_000 });
      } catch (err: any) {
        failed.push({ name: check.name, output: String(err.stderr || err.stdout || err.message).slice(0, 1000) });
      }
    }

    if (failed.length === 0) {
      this.bus.emit("LINT", "lint.passed", "All lint checks passed");
      await this.drainCommands();
      return;
    }

    const names = failed.map((f) => f.name).join(", ");
    this.bus.emit("LINT", "lint.failed", `Lint failed: ${names}`, { failed }, "warn");
    await this.drainCommands();

    if (this.retryCount >= MAX_RETRIES) {
      await this.escalate(`Lint loop hit max retries. Failing: ${names}`);
      return;
    }

    this.retryCount++;
    this.bus.setRetryCount(this.retryCount);
    const feedback = `LINT FAILURE:\n${failed.map((f) => `- ${f.name} failed:\n${f.output}`).join("\n\n")}\n\nFix all lint errors before resubmitting.`;
    await this.build(feedback);
    await this.lint();
  }

  private async verify(): Promise<void> {
    this.bus.emit("VERIFY", "verify.started", "Starting verification phase");

    const sessionContent = await this.readLatestBuilderSession();
    const verifierModel =
      sessionContent.length >= TIER2_CHAR_THRESHOLD
        ? VERIFIER_MODEL_128K
        : VERIFIER_MODEL_64K;
    const maxChars = verifierModel === VERIFIER_MODEL_128K ? 496_000 : 240_000;
    const truncated = truncateSession(sessionContent, maxChars);

    const report = await this.runVerifier(truncated, verifierModel);
    this.lastReport = report;

    if (report.status === "PASSED") {
      this.bus.emit("VERIFY", "verify.passed", `PASSED — ${report.report.verified}/${report.report.total_claims} claims verified`);
      await this.drainCommands();
      this.done();
      return;
    }

    this.bus.emit("VERIFY", "verify.failed", `FAILED — ${report.report.failed} failed, ${report.report.unverified} unverified`, { report: report.report }, "warn");
    await this.drainCommands();

    if (this.retryCount >= MAX_RETRIES) {
      await this.escalate(`Verifier failed after ${MAX_RETRIES} retries`);
      return;
    }

    this.retryCount++;
    this.bus.setRetryCount(this.retryCount);
    await this.build(report.report.feedback_for_builder ?? "Verification failed.");
    await this.lint();
    await this.verify();
  }

  private async drainCommands(): Promise<void> {
    const cmds = this.bus.drainCommands();
    for (const cmd of cmds) this.handleCommand(cmd);

    while (this.pauseRequested) {
      process.stderr.write("[PAUSE] Paused. Awaiting 'continue' command...\n");
      await new Promise((r) => setTimeout(r, 2000));
      const newCmds = this.bus.drainCommands();
      for (const c of newCmds) this.handleCommand(c);
    }
  }

  private handleCommand(cmd: IncomingCommand): void {
    switch (cmd.command) {
      case "abort":
        this.abortRequested = true;
        this.bus.emit("INIT", "command.received", "Abort requested", {}, "warn");
        break;
      case "pause":
        this.pauseRequested = true;
        break;
      case "continue":
        this.pauseRequested = false;
        break;
      case "inject":
        if (cmd.message) {
          this.pendingInjects.push(cmd.message);
          this.bus.emit("BUILD", "command.received", `Inject queued: "${cmd.message.slice(0, 60)}..."`);
        }
        break;
      case "status":
        this.bus.emit("BUILD", "command.received",
          `Status: retry=${this.retryCount}/${MAX_RETRIES}`,
          { retry_count: this.retryCount, last_report_status: this.lastReport?.status ?? null });
        break;
    }
  }

  private done(): void {
    this.bus.emit("DONE", "task.completed", "Task verified. Ready for PR.");
    process.stdout.write(JSON.stringify({ status: "DONE", report: this.lastReport }) + "\n");
  }

  private async escalate(reason: string): Promise<never> {
    this.bus.emit("ESCALATE", "task.escalated", reason, { retries: this.retryCount }, "error");
    return process.exit(1);
  }

  private async readLatestBuilderSession(): Promise<string> {
    const files = (await readdir(SESSIONS_DIR))
      .filter((f) => f.endsWith(".jsonl"))
      .sort();
    if (files.length === 0) throw new Error(`No session files in ${SESSIONS_DIR}`);
    return readFile(join(SESSIONS_DIR, files[files.length - 1]), "utf-8");
  }

  private async runVerifier(sessionContent: string, modelId: string): Promise<VerifierReport> {
    const authStorage = AuthStorage.create();
    const modelRegistry = ModelRegistry.create(authStorage);

    const verifierModel = modelRegistry.find("llama-cpp-local", modelId);
    if (!verifierModel) throw new Error(`Verifier model not found: ${modelId}`);

    const { session } = await createAgentSession({
      sessionManager: SessionManager.inMemory(),
      authStorage,
      modelRegistry,
      model: verifierModel,
      cwd: WORKSPACE_DIR,
      agentDir: VERIFIER_CWD,
    });

    const collector = this.attachObserver(session, "VERIFY");

    const prompt = [
      "BUILDER SESSION LOG (JSONL):",
      sessionContent,
      "---",
      "VERIFICATION TASK:",
      `Original task: ${this.task}`,
      "",
      "Audit the session log. Return only the JSON report as specified in your instructions.",
    ].join("\n");

    await session.prompt(prompt);
    const raw = collector.text;
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
          feedback_for_builder: "Verifier output could not be parsed.",
        },
      };
    }
  }
}

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
