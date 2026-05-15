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

  # Fire verifier — write session to file to avoid tmux newline injection
  echo "[coordinator] Firing verifier (attempt $((retry + 1))/$((MAX_RETRIES + 1)))..."
  session_file="/tmp/bv-verifier-session.jsonl"
  cp "$latest" "$session_file"

  task_oneline=$(echo "$task" | tr '\n' ' ')
  verifier_prompt="Read the file $session_file — it contains the builder's JSONL session log. Then audit it against this task: $task_oneline — Return only the JSON report as specified in your instructions."
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
