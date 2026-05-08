const BLOCKED = new Set(["write", "edit", "bash"]);
export default function load(pi: any) {
  pi.on("tool_call", async (event: any) => {
    if (BLOCKED.has(event.tool)) {
      return { error: `Verifier: '${event.tool}' is disabled.` };
    }
    return undefined;
  });
}
