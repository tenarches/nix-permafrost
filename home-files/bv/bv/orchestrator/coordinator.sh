#!/usr/bin/env bash
# ~/bv/orchestrator/coordinator.sh
# Interactive coordinator: drives builder → verifier → feedback loop via tmux.

set -euo pipefail

SESSIONS_DIR="$HOME/bv/sessions"
SESSION_NAME="bv"
VERIFIER_PANE="$SESSION_NAME:0.1"
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
printf '/skill:prime\n\n%s' "$task" > /tmp/bv-builder-task.txt
tmux load-buffer /tmp/bv-builder-task.txt
tmux paste-buffer -p -t "$BUILDER_PANE"
tmux send-keys -t "$BUILDER_PANE" Enter
rm -f /tmp/bv-builder-task.txt
echo "[coordinator] Task sent to builder."

# --- Main loop ---
while true; do
  # Wait for builder to finish (session file stops growing)
  echo "[coordinator] Waiting for builder..."
  while true; do
    latest=$(ls -t "$SESSIONS_DIR"/*.jsonl 2>/dev/null | head -1) || true
    [[ -z "$latest" ]] && { sleep 2; continue; }

    size_a=$(stat -c%s "$latest")
    sleep 10
    size_b=$(stat -c%s "$latest")
    [[ "$size_a" -ne "$size_b" ]] && { echo "[coordinator] Builder still running..."; continue; }

    echo "[coordinator] Builder turn complete (${latest})."
    break
  done

  # Fire verifier — use bracketed paste to send multi-line content safely
  echo "[coordinator] Firing verifier (attempt $((retry + 1))/$((MAX_RETRIES + 1)))..."
  session_content=$(cat "$latest")
  session_len=${#session_content}
  MAX_SESSION_CHARS=240000
  if [[ $session_len -gt $MAX_SESSION_CHARS ]]; then
    echo "[coordinator] Session too large (${session_len} chars), truncating to ${MAX_SESSION_CHARS}..."
    session_content="${session_content:0:$MAX_SESSION_CHARS}"
  fi
  verifier_prompt="BUILDER SESSION LOG (JSONL):
$session_content
---
VERIFICATION TASK:
Original task: $task

Audit the session log. Return only the JSON report as specified in your instructions."

  printf '%s' "$verifier_prompt" > /tmp/bv-verifier-prompt.txt
  tmux load-buffer /tmp/bv-verifier-prompt.txt
  tmux paste-buffer -p -t "$VERIFIER_PANE"
  tmux send-keys -t "$VERIFIER_PANE" Enter
  rm -f /tmp/bv-verifier-prompt.txt

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
  feedback=$(echo "$report_json" | jq -r '.report.feedback_for_builder // "Verification failed. Review and fix."' | tr '\n' ' ')
  retry=$((retry + 1))
  echo "[coordinator] Sending feedback to builder (retry $retry/$MAX_RETRIES)..."

  # Record baseline size before sending feedback to avoid race condition
  baseline_size=$(stat -c%s "$latest")

  tmux send-keys -t "$BUILDER_PANE" "VERIFIER FEEDBACK (attempt $retry/$MAX_RETRIES): $feedback — Address all feedback. Provide an updated COMPLETION SUMMARY." Enter

  # Wait for builder to start processing (file must grow past baseline)
  echo "[coordinator] Waiting for builder to begin processing feedback..."
  while true; do
    sleep 5
    current_size=$(stat -c%s "$latest" 2>/dev/null || echo "$baseline_size")
    [[ "$current_size" -gt "$baseline_size" ]] && break
    echo "[coordinator] Builder not started yet..."
  done

done
