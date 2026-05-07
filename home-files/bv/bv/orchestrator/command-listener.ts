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
