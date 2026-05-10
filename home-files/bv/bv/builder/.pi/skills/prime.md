---
description: "Load essential codebase context before starting any implementation task. Always run this before the first task in a session."
---

# Prime: Codebase Context Loader

Load essential project context before implementing anything. Prevents hallucinating
non-existent internal APIs and ensures the completion summary reflects the real
project structure.

## Steps

1. Read AGENTS.md for operational constraints
2. Read package.json to understand dependencies and available scripts
3. Run `ls -la` to understand the top-level directory structure
4. Read README.md or docs/README.md if present
5. Read the primary source entry point (e.g., src/index.ts, src/main.ts)
6. Read any ARCHITECTURE.md or similar overview files
7. If this is an existing codebase, run `git log --oneline -10` to understand
   recent activity
8. Report: "Context loaded. [project name]. Key facts: [2-3 sentences]. Ready."

Do not begin implementation until all steps above are complete.
