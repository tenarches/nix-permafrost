import crypto from "crypto";
import { type NotifyConfig, loadNotifyConfig } from "./notify-config.js";
import type { IncomingCommand } from "./command-listener.js";

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
  private commandQueue: IncomingCommand[] = [];

  constructor(sessionId: string) {
    this.sessionId = sessionId;
    this.config = loadNotifyConfig();
  }

  setRetryCount(n: number): void { this.retryCount = n; }

  emit(
    stage: NotificationStage,
    type: NotificationEventType,
    message: string,
    payload?: Record<string, unknown>,
    level: NotificationLevel = "info",
  ): void {
    const event: NotificationEvent = {
      id: crypto.randomUUID(),
      session_id: this.sessionId,
      timestamp: new Date().toISOString(),
      stage, type, level, message,
      retry_count: this.retryCount,
      payload,
    };

    process.stderr.write(`[${event.timestamp}] [${stage}] [${type}] ${message}\n`);

    if (this.config.webhookUrl && this.shouldNotify(type)) {
      this.fireWebhook(event).catch((err) => {
        process.stderr.write(`[NOTIFY] Webhook delivery failed (non-fatal): ${err}\n`);
      });
    }
  }

  drainCommands(): IncomingCommand[] {
    const cmds = [...this.commandQueue];
    this.commandQueue = [];
    return cmds;
  }

  enqueueCommand(cmd: IncomingCommand): void {
    this.commandQueue.push(cmd);
    this.emit("INIT", "command.received", `Command received: ${cmd.command}`, {
      command: cmd.command,
      has_message: !!cmd.message,
    });
  }

  private shouldNotify(type: NotificationEventType): boolean {
    const { eventFilter } = this.config;
    if (!eventFilter || eventFilter.length === 0) return true;
    return eventFilter.includes(type);
  }

  private async fireWebhook(event: NotificationEvent): Promise<void> {
    const { webhookUrl, webhookSecret, timeoutMs = 5000, retries = 3 } = this.config;

    const body = JSON.stringify(event);
    const headers: Record<string, string> = { "Content-Type": "application/json" };

    if (webhookSecret) {
      const sig = crypto.createHmac("sha256", webhookSecret).update(body).digest("hex");
      headers["X-BV-Signature"] = `sha256=${sig}`;
    }

    for (let attempt = 1; attempt <= retries; attempt++) {
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), timeoutMs);
      try {
        const res = await fetch(webhookUrl!, { method: "POST", headers, body, signal: controller.signal });
        clearTimeout(timer);
        if (res.ok) return;
        process.stderr.write(`[NOTIFY] Webhook attempt ${attempt}/${retries}: HTTP ${res.status}\n`);
      } catch (err) {
        clearTimeout(timer);
        if (attempt === retries) throw err;
        await new Promise((r) => setTimeout(r, 1000 * 2 ** (attempt - 1)));
      }
    }
  }
}
