# BV Verifier Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the BV verifier actually perform verification by fixing response extraction, adding session truncation, correcting model config, and adding a coordinator feedback loop.

**Architecture:** The builder-verifier system runs two Pi agent sessions — a builder (Gemini) generates code while a verifier (Qwen 3.6 via llama.cpp) audits the builder's session log. The orchestrator (headless TypeScript) and coordinator (interactive tmux/bash) both drive this lifecycle. Four fixes address the broken verification path.

**Tech Stack:** TypeScript (ESNext modules, tsx runner), bash (tmux scripting), Pi Coding Agent SDK (`@earendil-works/pi-coding-agent`), llama.cpp OpenAI-compatible API.

**Spec:** `docs/superpowers/specs/2026-05-15-bv-verifier-fix-design.md`

---

## File Map

| File | Role | Changes |
|---|---|---|
| `home-files/bv/bv/orchestrator/orchestrator.ts` | Headless orchestrator | Fix `attachObserver` to return `TextCollector`, fix `runVerifier` to use collector, add `truncateSession()` |
| `home-files/bv/bv/verifier/.pi/extensions/verifier-provider.ts` | Verifier model registration | Change `api` to `"openai"`, `reasoning` to `true` |
| `home-files/shared/.pi/agent/models.json` | Shared model config | Change `api` to `"openai"` on both providers |
| `home-files/bv/bv/orchestrator/coordinator.sh` | Interactive tmux coordinator | Add retry loop, JSON extraction, feedback path |
| `home-files/bv/bv/orchestrator/init-bv.sh` | tmux layout setup | Add `history-limit 50000` |

---

### Task 1: Fix API Type and Reasoning Flags

The simplest, most self-contained fix. Changes static config values — no logic involved.

**Files:**
- Modify: `home-files/bv/bv/verifier/.pi/extensions/verifier-provider.ts:8,17,27`
- Modify: `home-files/shared/.pi/agent/models.json:8,30`

- [ ] **Step 1: Fix `api` and `reasoning` in `verifier-provider.ts`**

In `home-files/bv/bv/verifier/.pi/extensions/verifier-provider.ts`, make three changes:

Change line 8 from:
```typescript
    api: "openai-completions",
```
to:
```typescript
    api: "openai",
```

Change line 17 from:
```typescript
        reasoning: false,
```
to:
```typescript
        reasoning: true,
```

Change line 27 from:
```typescript
        reasoning: false,
```
to:
```typescript
        reasoning: true,
```

- [ ] **Step 2: Fix `api` in `models.json`**

In `home-files/shared/.pi/agent/models.json`, change BOTH provider entries' `api` field.

Change line 8 from:
```json
      "api": "openai-completions",
```
to:
```json
      "api": "openai",
```

Change line 30 from:
```json
      "api": "openai-completions",
```
to:
```json
      "api": "openai",
```

- [ ] **Step 3: Verify the changes**

Run:
```bash
grep -n '"api"' home-files/shared/.pi/agent/models.json home-files/bv/bv/verifier/.pi/extensions/verifier-provider.ts
grep -n 'reasoning' home-files/bv/bv/verifier/.pi/extensions/verifier-provider.ts
```

Expected: all `api` values show `"openai"`, both `reasoning` values show `true`.

- [ ] **Step 4: Commit**

```bash
git add home-files/bv/bv/verifier/.pi/extensions/verifier-provider.ts home-files/shared/.pi/agent/models.json
git commit -m "fix(bv): correct api type to 'openai' and enable reasoning on verifier models"
```

---

### Task 2: Fix Response Extraction in `attachObserver`

Replace the broken `session.getLastAssistantText()` call with event-stream text accumulation. This is the core fix that makes the verifier work.

**Files:**
- Modify: `home-files/bv/bv/orchestrator/orchestrator.ts:137-167,323-354`

- [ ] **Step 1: Add `TextCollector` interface**

In `home-files/bv/bv/orchestrator/orchestrator.ts`, add the `TextCollector` interface after the `VerifierReport` interface (after line 67, before the Orchestrator class):

```typescript
interface TextCollector {
  text: string;
}
```

- [ ] **Step 2: Modify `attachObserver` to return a `TextCollector`**

Change the `attachObserver` method signature and body. The current method (lines 137-167) is:

```typescript
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
```

Replace the full method with:

```typescript
  private attachObserver(session: any, label: string): TextCollector {
    const collector: TextCollector = { text: "" };
    const onEvent = (event: any) => {
      if (!event) return;
      switch (event.type) {
        case "message_update": {
          const ae = event.assistantMessageEvent;
          if (!ae) return;
          if (ae.type === "text_delta") {
            collector.text += ae.delta;
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
    return collector;
  }
```

- [ ] **Step 3: Update `init()` to use the returned collector (discard it)**

The builder's `attachObserver` call on line 131 currently returns `void`. Now it returns a `TextCollector` — we don't need the builder's text, so just ignore the return value. No change needed since the return value is already discarded.

Verify line 131 reads:
```typescript
    this.attachObserver(session, "BUILDER");
```

This is fine — TypeScript allows ignoring return values.

- [ ] **Step 4: Update `runVerifier` to use the collector**

Replace lines 339-353 of `runVerifier` (the section after session creation, starting from the `attachObserver` call through `return this.parseReport(raw)`):

Current code:
```typescript
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
    const raw = session.getLastAssistantText() ?? "";
    return this.parseReport(raw);
```

Replace with:
```typescript
    const collector = this.attachObserver(session, "VERIFY");

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
    const raw = collector.text;
    return this.parseReport(raw);
```

- [ ] **Step 5: Verify TypeScript compiles**

Run from `home-files/bv/bv/orchestrator/`:
```bash
npx tsc --noEmit
```

Expected: no errors (or only pre-existing errors unrelated to these changes). The key check is that `session.getLastAssistantText()` is gone and `collector.text` is used instead.

If `tsc` isn't available in this context, verify with grep:
```bash
grep -n "getLastAssistantText" home-files/bv/bv/orchestrator/orchestrator.ts
```
Expected: no matches.

- [ ] **Step 6: Commit**

```bash
git add home-files/bv/bv/orchestrator/orchestrator.ts
git commit -m "fix(bv): replace broken getLastAssistantText with event-stream text accumulation"
```

---

### Task 3: Add Session Truncation

Implement `truncateSession()` so large builder sessions don't exceed the Qwen model's context window. This function processes the raw JSONL content, keeps priority entries, and fills remaining budget with recent entries.

**Files:**
- Modify: `home-files/bv/bv/orchestrator/orchestrator.ts` (add function + call site)

- [ ] **Step 1: Add the `truncateSession` function**

Add this function after the `TextCollector` interface and before the `Orchestrator` class. It operates on raw JSONL text (each line is a JSON object):

```typescript
function truncateSession(content: string, maxChars: number): string {
  if (content.length <= maxChars) return content;

  const lines = content.split("\n").filter((l) => l.trim());
  const priority: string[] = [];
  const rest: string[] = [];

  for (const line of lines) {
    let isPriority = false;
    try {
      const entry = JSON.parse(line);
      if (entry.type === "bashExecution") isPriority = true;
      if (entry.type === "tool_result" && (entry.name === "write" || entry.name === "edit")) isPriority = true;
    } catch {
      // non-JSON line, treat as non-priority
    }
    if (isPriority) {
      priority.push(line);
    } else {
      rest.push(line);
    }
  }

  // Last entry is always kept (completion summary)
  const lastEntry = lines[lines.length - 1];
  const hasLastInPriority = priority.length > 0 && priority[priority.length - 1] === lastEntry;
  if (!hasLastInPriority && lastEntry) {
    priority.push(lastEntry);
    const lastIdx = rest.lastIndexOf(lastEntry);
    if (lastIdx !== -1) rest.splice(lastIdx, 1);
  }

  let budget = maxChars;
  const kept: string[] = [];

  // Priority entries first
  for (const line of priority) {
    if (budget - line.length - 1 < 0) break;
    kept.push(line);
    budget -= line.length + 1;
  }

  // Fill remaining budget with non-priority entries, newest first
  for (let i = rest.length - 1; i >= 0; i--) {
    if (budget - rest[i].length - 1 < 0) break;
    kept.unshift(rest[i]);
    budget -= rest[i].length + 1;
  }

  return kept.join("\n");
}
```

- [ ] **Step 2: Add truncation call in `verify()`**

In the `verify()` method, add the truncation call between reading the session and calling `runVerifier`. Current code (lines 236-242):

```typescript
    const sessionContent = await this.readLatestBuilderSession();
    const verifierModel =
      sessionContent.length >= TIER2_CHAR_THRESHOLD
        ? VERIFIER_MODEL_128K
        : VERIFIER_MODEL_64K;

    const report = await this.runVerifier(sessionContent, verifierModel);
```

Replace with:
```typescript
    const sessionContent = await this.readLatestBuilderSession();
    const verifierModel =
      sessionContent.length >= TIER2_CHAR_THRESHOLD
        ? VERIFIER_MODEL_128K
        : VERIFIER_MODEL_64K;
    const maxChars = verifierModel === VERIFIER_MODEL_128K ? 496_000 : 240_000;
    const truncated = truncateSession(sessionContent, maxChars);

    const report = await this.runVerifier(truncated, verifierModel);
```

- [ ] **Step 3: Verify no TypeScript errors**

```bash
grep -n "truncateSession" home-files/bv/bv/orchestrator/orchestrator.ts
```

Expected: the function definition and exactly one call site in `verify()`.

- [ ] **Step 4: Commit**

```bash
git add home-files/bv/bv/orchestrator/orchestrator.ts
git commit -m "feat(bv): add session truncation to fit verifier context window"
```

---

### Task 4: Add Scrollback Buffer to `init-bv.sh`

Set a generous tmux scrollback limit so the verifier's JSON report isn't lost from pane history during coordinator capture.

**Files:**
- Modify: `home-files/bv/bv/orchestrator/init-bv.sh:17` (insert after pane-border-style line)

- [ ] **Step 1: Add history-limit setting**

In `home-files/bv/bv/orchestrator/init-bv.sh`, add a `history-limit` line after the existing `tmux set-option` block. Insert after line 20 (the `pane-border-style` line):

```bash
tmux set-option -t "$SESSION" history-limit 50000
```

The block should read:
```bash
tmux set-option -t "$SESSION" pane-border-status top
tmux set-option -t "$SESSION" pane-border-format " #[fg=black,bg=cyan,bold] #T #[default] "
tmux set-option -t "$SESSION" pane-active-border-style fg=cyan
tmux set-option -t "$SESSION" pane-border-style fg=white
tmux set-option -t "$SESSION" history-limit 50000
```

- [ ] **Step 2: Verify**

```bash
grep -n "history-limit" home-files/bv/bv/orchestrator/init-bv.sh
```

Expected: one match with value `50000`.

- [ ] **Step 3: Commit**

```bash
git add home-files/bv/bv/orchestrator/init-bv.sh
git commit -m "fix(bv): set tmux history-limit to 50000 for verifier output capture"
```

---

### Task 5: Add Coordinator Feedback Loop

Replace the fire-once coordinator with a full retry loop that captures verifier output, parses the JSON report, and feeds failures back to the builder. This is the interactive-mode equivalent of the orchestrator's retry logic.

**Files:**
- Modify: `home-files/bv/bv/orchestrator/coordinator.sh` (full rewrite of the main loop)

- [ ] **Step 1: Rewrite `coordinator.sh`**

Replace the entire contents of `home-files/bv/bv/orchestrator/coordinator.sh` with:

```bash
#!/usr/bin/env bash
# ~/bv/orchestrator/coordinator.sh
# Interactive coordinator: drives builder → verifier → feedback loop via tmux.

set -euo pipefail

SESSIONS_DIR="$HOME/bv/sessions"
SESSION_NAME="bv"
VERIFIER_PANE="$SESSION_NAME:0.2"
BUILDER_PANE="$SESSION_NAME:0.0"

MAX_RETRIES=2
retry=0

task_file="${1:?Usage: coordinator.sh <task-file>}"

if ! tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
  echo "[error] tmux session '$SESSION_NAME' not found."
  echo "        Run './init-bv.sh' first."
  exit 1
fi

task=$(cat "$task_file")

# --- Helper: wait for a pane to go idle (output stops changing) ---
wait_for_idle() {
  local pane="$1"
  local label="$2"
  local interval="${3:-10}"

  while true; do
    local snap_a
    snap_a=$(tmux capture-pane -p -t "$pane" -S -100)
    sleep "$interval"
    local snap_b
    snap_b=$(tmux capture-pane -p -t "$pane" -S -100)

    if [[ "$snap_a" == "$snap_b" ]]; then
      echo "[coordinator] $label idle."
      return
    fi
    echo "[coordinator] $label still running..."
  done
}

# --- Helper: extract JSON report from verifier pane ---
extract_report() {
  local captured
  captured=$(tmux capture-pane -p -t "$VERIFIER_PANE" -S -500)

  # Find the JSON report — look for {"status": pattern
  local json
  json=$(echo "$captured" | grep -o '{"status":.*' | tail -1) || true

  if [[ -z "$json" ]]; then
    echo ""
    return
  fi

  # Validate it's parseable JSON
  if echo "$json" | jq . >/dev/null 2>&1; then
    echo "$json"
  else
    echo ""
  fi
}

# --- Send initial task to builder ---
tmux send-keys -t "$BUILDER_PANE" "/skill:prime

$task" Enter
echo "[coordinator] Task sent to builder."

# --- Main loop ---
while true; do
  # Wait for builder to finish (session file stops growing)
  echo "[coordinator] Waiting for builder..."
  while true; do
    latest=$(ls -t "$SESSIONS_DIR"/*.jsonl 2>/dev/null | head -1)
    [[ -z "$latest" ]] && { sleep 2; continue; }

    size_a=$(stat -c%s "$latest")
    sleep 10
    size_b=$(stat -c%s "$latest")
    [[ "$size_a" -ne "$size_b" ]] && { echo "[coordinator] Builder still running..."; continue; }

    echo "[coordinator] Builder turn complete (${latest})."
    break
  done

  # Fire verifier with session content
  echo "[coordinator] Firing verifier (attempt $((retry + 1))/$((MAX_RETRIES + 1)))..."
  session_content=$(cat "$latest")
  verifier_prompt="BUILDER SESSION LOG (JSONL):
$session_content
---
VERIFICATION TASK:
Original task: $task

Audit the session log. Return only the JSON report."

  tmux send-keys -t "$VERIFIER_PANE" "$verifier_prompt" Enter

  # Wait for verifier to finish
  wait_for_idle "$VERIFIER_PANE" "Verifier" 10

  # Extract and parse the report
  report_json=$(extract_report)

  if [[ -z "$report_json" ]]; then
    echo "[coordinator] WARNING: Could not extract JSON report from verifier pane."
    echo "[coordinator] Check verifier pane manually."
    exit 1
  fi

  status=$(echo "$report_json" | jq -r '.status')
  echo "[coordinator] Verifier status: $status"

  if [[ "$status" == "PASSED" ]]; then
    echo "[coordinator] PASSED. Task verified successfully."
    echo "$report_json" | jq .
    exit 0
  fi

  # FAILED — check retry budget
  if [[ $retry -ge $MAX_RETRIES ]]; then
    echo "[coordinator] FAILED after $((MAX_RETRIES + 1)) attempts. Escalating."
    echo "$report_json" | jq .
    exit 1
  fi

  # Extract feedback and send back to builder
  feedback=$(echo "$report_json" | jq -r '.report.feedback_for_builder // "Verification failed. Review and fix."')
  echo "[coordinator] Sending feedback to builder (retry $((retry + 1)))..."

  retry=$((retry + 1))
  tmux send-keys -t "$BUILDER_PANE" "VERIFIER FEEDBACK (attempt $retry/$MAX_RETRIES):

$feedback

Address all feedback. Provide an updated COMPLETION SUMMARY." Enter

done
```

- [ ] **Step 2: Verify the script is syntactically valid**

```bash
bash -n home-files/bv/bv/orchestrator/coordinator.sh
```

Expected: no output (syntax OK).

- [ ] **Step 3: Verify key features are present**

```bash
grep -c "extract_report\|wait_for_idle\|MAX_RETRIES\|feedback_for_builder\|jq" home-files/bv/bv/orchestrator/coordinator.sh
```

Expected: count >= 5, confirming all key features are in the script.

- [ ] **Step 4: Commit**

```bash
git add home-files/bv/bv/orchestrator/coordinator.sh
git commit -m "feat(bv): add coordinator retry loop with verifier feedback path"
```

---

## Summary of Changes

After all 5 tasks:

1. **Task 1** — Config fix: `api: "openai"` + `reasoning: true` on both verifier models
2. **Task 2** — Core fix: event-stream text accumulation replaces broken `getLastAssistantText()`
3. **Task 3** — Robustness: session truncation prevents context window overflow
4. **Task 4** — Infra: tmux scrollback buffer for coordinator capture reliability
5. **Task 5** — Interactive mode: full retry loop with JSON extraction and builder feedback

The verifier will produce real verification reports after these changes. The headless orchestrator (Tasks 1-3) and interactive coordinator (Tasks 4-5) are independent paths — both will work.
