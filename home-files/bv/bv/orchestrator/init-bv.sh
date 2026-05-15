#!/usr/bin/env bash
# ~/bv/orchestrator/init-bv.sh
# Sets up the 4-pane tmux layout for the Builder-Verifier workflow.
#
# Layout (pane indices after splits):
# +-------------------------------+-------------------------------+
# |  BUILDER [Gemini] (0.0)       |  VERIFIER [Qwen] (0.2)       |
# |  70% height                   |                               |
# +-------------------------------+-------------------------------+
# |  COORDINATOR (0.1)            |  SESSION LOG (0.3)            |
# |  30% height                   |                               |
# +-------------------------------+-------------------------------+

set -euo pipefail

SESSION="bv"
LLAMA_ENDPOINT="${LLAMA_CPP_ENDPOINT:-http://dualie.home.lan:8001}"

if tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "Session '$SESSION' already exists."
  echo "  Attach:  tmux attach -t $SESSION"
  echo "  Kill:    tmux kill-session -t $SESSION"
  exit 0
fi

# --- Preflight: check llama.cpp endpoint ---
echo "[init] Checking verifier endpoint ($LLAMA_ENDPOINT)..."
if curl -sf --max-time 3 "$LLAMA_ENDPOINT/v1/models" >/dev/null 2>&1; then
  echo "[init] Verifier endpoint OK."
else
  echo "[warn] Verifier endpoint at $LLAMA_ENDPOINT is not responding."
  echo "       The verifier will fail until llama-server is running."
  echo "       Continuing with layout setup..."
fi

# --- Create session ---
tmux new-session -d -s "$SESSION" -n "builder-verifier"

# --- Session-wide options ---
tmux set-option -t "$SESSION" pane-border-status top
tmux set-option -t "$SESSION" pane-border-format \
  " #[fg=black,bg=cyan,bold] #{pane_index}: #T #[default] "
tmux set-option -t "$SESSION" pane-active-border-style "fg=cyan,bold"
tmux set-option -t "$SESSION" pane-border-style fg=colour240
tmux set-option -t "$SESSION" history-limit 50000

# --- Create 4-pane layout ---
# Step 1: Split vertically — top gets 70% for the agents, bottom 30% for support.
#   Before: pane 0 (full)
#   After:  pane 0 (top 70%), pane 1 (bottom 30%)
tmux split-window -v -p 30 -t "$SESSION:0.0"

# Step 2: Split top pane horizontally — builder left, verifier right.
#   After:  pane 0 (top-left), pane 2 (top-right), pane 1 (bottom)
tmux split-window -h -t "$SESSION:0.0"

# Step 3: Split bottom pane horizontally — coordinator left, log watcher right.
#   After:  pane 0 (TL), pane 2 (TR), pane 1 (BL), pane 3 (BR)
tmux split-window -h -t "$SESSION:0.1"

# --- Label and launch each pane ---

# Pane 0 (top-left): Builder — Gemini via Pi
tmux select-pane -t "$SESSION:0.0" -T "BUILDER [Gemini]"
tmux send-keys -t "$SESSION:0.0" \
  "export PI_CODING_AGENT_SETTINGS_DIR=~/.bv-logic/builder && cd ~/workspace && pi" Enter

# Pane 2 (top-right): Verifier — Qwen via Pi + local llama.cpp
tmux select-pane -t "$SESSION:0.2" -T "VERIFIER [Qwen]"
tmux send-keys -t "$SESSION:0.2" \
  "export PI_CODING_AGENT_SETTINGS_DIR=~/.bv-logic/verifier && cd ~/workspace && pi" Enter

# Pane 1 (bottom-left): Coordinator — where you run tasks
tmux select-pane -t "$SESSION:0.1" -T "COORDINATOR"
tmux send-keys -t "$SESSION:0.1" "cd ~/.bv-logic/orchestrator && clear && echo '
=== BV Coordinator ===
Run a task:  ./coordinator.sh path/to/task.md
Headless:    npm start -- --task \"description\"
'" Enter

# Pane 3 (bottom-right): Live session log — waits for files if none exist yet
tmux select-pane -t "$SESSION:0.3" -T "SESSION LOG"
tmux send-keys -t "$SESSION:0.3" \
  "echo '[log] Watching ~/bv/sessions/ for JSONL files...' && until ls ~/bv/sessions/*.jsonl >/dev/null 2>&1; do sleep 2; done && tail -F ~/bv/sessions/*.jsonl" Enter

# --- Focus coordinator pane (where the engineer types) ---
tmux select-pane -t "$SESSION:0.1"

echo ""
echo "BV layout ready. Attach with:"
echo "  tmux attach -t $SESSION"
echo ""
echo "Pane layout:"
echo "  0: BUILDER [Gemini]     2: VERIFIER [Qwen]"
echo "  1: COORDINATOR          3: SESSION LOG"
