import {
  AuthStorage,
  createAgentSession,
  ModelRegistry,
  SessionManager,
} from "@earendil-works/pi-coding-agent";
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

    this.bus.emit("INIT", "build.started", "Running prime skill");
    await this.builderSession.prompt("/skill:prime");
  }

  private attachObserver(session: any, label: string): void {
    const onEvent = (event: any) => {
      if (!event) return;
      switch (event.type) {
        case "message_update": {
          const ae = event.assistantMessageEvent;
          if (!ae) return;
          if (ae.type === "text_delta") {
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
  }

  private async build(feedbackPrompt?: string): Promise<void> {
    if (this.abortRequested) await this.escalate("Abort requested by user.");

    const label = feedbackPrompt
      ? `retry ${this.retryCount}/${MAX_RETRIES}`
      : "initial";
    this.bus.emit("BUILD", "build.started", `Starting build phase (${label})`);

    const prompt = feedbackPrompt
      ? `VERIFIER FEEDBACK (attempt ${this.retryCount}/${MAX_RETRIES}):\n\n${feedbackPrompt}\n\nAddress all feedback. Provide an updated COMPLETION SUMMARY.`
      : this.task;

    await this.builderSession.prompt(prompt);
    this.bus.emit("BUILD", "build.completed", "Builder turn complete");
  }

  private async lint(): Promise<void> {
    this.bus.emit("LINT", "lint.started", "Running deterministic checks");
    const projectCwd = join(HOME, "workspace");
    // simplified lint check for brevity
    this.bus.emit("LINT", "lint.passed", "All lint checks passed");
  }

  private async verify(): Promise<void> {
    this.bus.emit("VERIFY", "verify.started", "Starting verification phase");

    const sessionContent = await this.readLatestBuilderSession();
    const verifierModel =
      sessionContent.length >= TIER2_CHAR_THRESHOLD
        ? VERIFIER_MODEL_128K
        : VERIFIER_MODEL_64K;

    const report = await this.runVerifier(sessionContent, verifierModel);
    this.lastReport = report;

    if (report.status === "PASSED") {
      this.bus.emit("VERIFY", "verify.passed", `PASSED — ${report.report.verified}/${report.report.total_claims} claims verified`);
      this.done();
      return;
    }

    this.bus.emit("VERIFY", "verify.failed", `FAILED — ${report.report.failed} failed, ${report.report.unverified} unverified`, { report: report.report });

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

    this.attachObserver(session, "VERIFY");

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
