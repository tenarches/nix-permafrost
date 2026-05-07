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
    process.stderr.write(`[${event.timestamp}] [${stage}] [${type}] ${message}\n`);
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
