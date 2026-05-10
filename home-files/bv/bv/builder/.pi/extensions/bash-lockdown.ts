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
      return { error: `SECURITY: '${base}' not in bash allowlist.` };
    }
    return undefined;
  });
}
