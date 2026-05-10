#!/usr/bin/env bash
# ~/bv/orchestrator/coordinator.sh
# Waits for the builder to finish a turn, then fires the verifier.

SESSIONS_DIR="$HOME/bv/sessions"
SESSION_NAME="bv"
VERIFIER_PANE="$SESSION_NAME:0.2"
BUILDER_PANE="$SESSION_NAME:0.0"

task_file="${1:?Usage: coordinator.sh <task-file>}"

if ! tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
  echo "[error] tmux session '$SESSION_NAME' not found."
  echo "        Run './init-bv.sh' first."
  exit 1
fi

task=$(cat "$task_file")

# Send task to builder
tmux send-keys -t "$BUILDER_PANE" "/skill:prime

$task" Enter

echo "[coordinator] Task sent to builder. Waiting for session..."

while true; do
  latest=$(ls -t "$SESSIONS_DIR"/*.jsonl 2>/dev/null | head -1)
  [[ -z "$latest" ]] && { sleep 2; continue; }

  size_a=$(stat -c%s "$latest"); sleep 10; size_b=$(stat -c%s "$latest")
  [[ "$size_a" -ne "$size_b" ]] && { echo "[coordinator] Builder still running..."; continue; }

  echo "[coordinator] Builder turn complete (${latest}). Firing verifier..."

  session_content=$(cat "$latest")
  verifier_prompt="BUILDER SESSION LOG (JSONL):
$session_content
---
VERIFICATION TASK:
Original task: $task

Audit the session log. Return only the JSON report."

  tmux send-keys -t "$VERIFIER_PANE" "$verifier_prompt" Enter
  echo "[coordinator] Verifier running. Check pane 2."
  break
done
