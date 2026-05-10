import { createServer, type IncomingMessage, type ServerResponse } from "http";
import type { NotificationBus } from "./notify.js";
import type { NotifyConfig } from "./notify-config.js";

export interface IncomingCommand {
  command: "continue" | "abort" | "inject" | "status" | "pause";
  message?: string;
  secret?: string;
}

const KNOWN_COMMANDS = new Set(["continue", "abort", "inject", "status", "pause"]);

export class CommandListener {
  private server: ReturnType<typeof createServer>;
  private bus: NotificationBus;
  private config: NotifyConfig;

  constructor(bus: NotificationBus, config: NotifyConfig) {
    this.bus = bus;
    this.config = config;
    this.server = createServer((req, res) => this.handle(req, res));
  }

  start(): void {
    const port = this.config.commandListenerPort ?? 9876;
    this.server.listen(port, "0.0.0.0", () => {
      process.stderr.write(`[COMMAND] Listener started on port ${port}\n`);
    });
  }

  stop(): void { this.server.close(); }

  private async handle(req: IncomingMessage, res: ServerResponse): Promise<void> {
    if (req.method !== "POST") {
      res.writeHead(405);
      res.end();
      return;
    }

    let body = "";
    for await (const chunk of req) body += chunk;

    let cmd: IncomingCommand;
    try {
      cmd = JSON.parse(body) as IncomingCommand;
    } catch {
      res.writeHead(400, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: "invalid JSON" }));
      return;
    }

    const expectedSecret = this.config.commandListenerSecret;
    if (expectedSecret && cmd.secret !== expectedSecret) {
      this.bus.emit("INIT", "command.rejected", "Command rejected: bad secret", {
        command: cmd.command,
      }, "warn");
      res.writeHead(403, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: "forbidden" }));
      return;
    }

    if (!KNOWN_COMMANDS.has(cmd.command)) {
      res.writeHead(400, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: `unknown command: ${cmd.command}` }));
      return;
    }

    if (cmd.command === "inject" && !cmd.message) {
      res.writeHead(400, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: "inject requires message" }));
      return;
    }

    this.bus.enqueueCommand(cmd);
    res.writeHead(202, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ accepted: true, command: cmd.command }));
  }
}
