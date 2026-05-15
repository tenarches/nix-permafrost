# BV Verifier Fix: Design Spec

**Date:** 2026-05-15
**Status:** Approved
**Scope:** Fix the verifier in the builder-verifier agent so it actually performs verification

---

## Problem Statement

The BV verifier is architecturally present but not performing actual verification.
Three root causes prevent it from working:

1. `session.getLastAssistantText()` likely doesn't exist in the Pi SDK, causing
   `runVerifier()` to always return a hardcoded FAILED/UNCERTAIN fallback with no
   real claim analysis.
2. No session truncation is implemented, so large session JSONL payloads exceed the
   Qwen model's context window and produce garbage or silent truncation.
3. The interactive coordinator (`coordinator.sh`) fires the verifier once with no
   retry loop, no JSON parsing, and no feedback path back to the builder.

Secondary issues: `api: "openai-completions"` may target the wrong endpoint,
and `reasoning: false` disables the verifier's thinking trace (hurting observability).

## Approach

Fix the Pi SDK integration path (Option C). The agent session framework provides
streaming observability via `attachObserver()` — replacing it with a raw HTTP call
would sacrifice the `[VERIFY:think]` traces, notification bus integration, and
consistency with the builder's event system.

---

## Fix 1: Response Extraction (orchestrator.ts)

Replace `session.getLastAssistantText()` with event-stream text accumulation.

`attachObserver()` already receives `text_delta` events from the Pi session. Modify
it to return a collector object that accumulates the assistant's text output:

```typescript
interface TextCollector {
  text: string;
}

function attachObserver(session: any, label: string): TextCollector {
  const collector: TextCollector = { text: "" };

  const onEvent = (event: any) => {
    // existing stderr logging...
    if (ae.type === "text_delta") {
      collector.text += ae.delta;          // NEW: accumulate
      process.stderr.write(...);           // existing logging
    }
    // ...rest unchanged
  };

  // existing event subscription...
  return collector;
}
```

In `runVerifier()`:

```typescript
const collector = this.attachObserver(session, "VERIFY");
await session.prompt(prompt);
const raw = collector.text;               // replaces getLastAssistantText()
return this.parseReport(raw);
```

**Why this works:** The event stream is proven functional — it's how the builder's
output is already observed. No dependency on an unknown SDK method.

---

## Fix 2: Session Truncation (orchestrator.ts)

Implement `truncateSession()` from the original spec (Section 9.3).

**Priority entries (always kept):**
- `bashExecution` — ground truth the verifier checks against
- `tool_result` for `write`/`edit` — file mutation evidence
- Last entry — typically contains the completion summary

**Budget fill:** Remaining space filled with non-priority entries in reverse order
(newest first), since recent context is most relevant to verification.

**Char budgets:**
- 64k model: ~240,000 chars
- 128k model: ~496,000 chars

Called in `verify()` between reading the session file and sending to verifier:

```typescript
const sessionContent = await this.readLatestBuilderSession();
const verifierModel = sessionContent.length >= TIER2_CHAR_THRESHOLD
    ? VERIFIER_MODEL_128K : VERIFIER_MODEL_64K;
const maxChars = verifierModel === VERIFIER_MODEL_128K ? 496_000 : 240_000;
const truncated = truncateSession(sessionContent, maxChars);
const report = await this.runVerifier(truncated, verifierModel);
```

If the session fits within budget, it passes through unchanged.

---

## Fix 3: API Type and Reasoning (verifier-provider.ts, models.json)

**API type:** Change `api: "openai-completions"` to `api: "openai"` in both
`verifier-provider.ts` and `shared/.pi/agent/models.json`. The conventional label
for the `/v1/chat/completions` endpoint in OpenAI-compatible frameworks is `"openai"`.
Pi's agent framework operates as a chat agent and should target chat completions.

**Reasoning:** Change `reasoning: false` to `reasoning: true` on both verifier
models. Qwen 3.6 supports thinking traces (`preserve_thinking: true` is configured
in the llama-server preset). Enabling reasoning gives the verifier a thinking chain
that flows through `attachObserver` as `[VERIFY:think]` — directly improving
observability.

### Files changed

- `home-files/bv/bv/verifier/.pi/extensions/verifier-provider.ts`
- `home-files/shared/.pi/agent/models.json`

---

## Fix 4: coordinator.sh Feedback Loop

Add the full retry loop to match the orchestrator's state machine.

### Detection and capture

- **Verifier completion:** Same heuristic as builder — pane output stops changing
  (compare `tmux capture-pane` output at two points 10s apart).
- **Output capture:** `tmux capture-pane -p -t $VERIFIER_PANE -S -500` dumps pane
  contents including scrollback.
- **JSON extraction:** grep for the `{"status":` pattern in captured output, pipe
  through `jq` for parsing.

### Loop structure

```
send task to builder
  → wait for builder (session file stops growing)
  → fire verifier with session content
  → wait for verifier (pane output stops changing)
  → capture pane, extract JSON report
  → PASSED? → exit 0
  → FAILED and retry < 2?
      → extract feedback_for_builder
      → send feedback to builder pane
      → increment retry, loop back to "wait for builder"
  → retry >= 2? → log ESCALATE, exit 1
```

### Scrollback buffer

`init-bv.sh` must set a generous scrollback limit so the verifier's JSON report
isn't lost from pane history:

```bash
tmux set-option -t "$SESSION" history-limit 50000
```

### Limitations

Interactive mode is inherently less reliable than headless mode. `tmux capture-pane`
only captures visible pane content plus scrollback. This matches the spec's guidance:
interactive mode is for prompt development and debugging, headless mode is for
production runs.

---

## Files Modified

| File | Change |
|---|---|
| `home-files/bv/bv/orchestrator/orchestrator.ts` | Fix 1 (response extraction), Fix 2 (truncation) |
| `home-files/bv/bv/verifier/.pi/extensions/verifier-provider.ts` | Fix 3 (api type, reasoning) |
| `home-files/shared/.pi/agent/models.json` | Fix 3 (api type) |
| `home-files/bv/bv/orchestrator/coordinator.sh` | Fix 4 (feedback loop) |
| `home-files/bv/bv/orchestrator/init-bv.sh` | Fix 4 (scrollback buffer) |

## Out of Scope

- Replacing the Pi SDK with direct HTTP calls (rejected: loses observability)
- Changing the builder's configuration or AGENTS.md
- Adding timeouts (Phase 4 hardening in the original spec — separate work)
- Fixing the notification bus webhook URL (placeholder value is a config concern)
