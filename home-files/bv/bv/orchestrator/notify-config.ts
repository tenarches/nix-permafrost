import { readFileSync, existsSync } from "fs";
import { homedir } from "os";
import { join } from "path";
import type { NotificationEventType } from "./notify.js";

export interface NotifyConfig {
  webhookUrl?: string;
  webhookSecret?: string;
  timeoutMs?: number;
  retries?: number;
  eventFilter?: NotificationEventType[];
  commandListenerEnabled?: boolean;
  commandListenerPort?: number;
  commandListenerSecret?: string;
  logLevel?: "info" | "debug";
}

export function loadNotifyConfig(): NotifyConfig {
  const candidates = [
    join(process.env.HOME ?? homedir(), ".bv-logic", "notify.json"),
    join(process.cwd(), "notify.json"),
  ];

  for (const path of candidates) {
    if (existsSync(path)) {
      try {
        return JSON.parse(readFileSync(path, "utf-8")) as NotifyConfig;
      } catch {
        process.stderr.write(`[NOTIFY] Failed to parse ${path} — using defaults\n`);
      }
    }
  }

  return {};
}
