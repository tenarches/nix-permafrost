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
