#!/usr/bin/env bash
# ~/bv/orchestrator/init-bv.sh
# Sets up the 4-pane tmux layout for the Builder-Verifier workflow.
#
# Layout (pane indices after splits):
# +-------------------------------+-------------------------------+
# |  BUILDER [Gemini] (0.0)       |  VERIFIER [Qwen] (0.1)       |
# |  70% height                   |                               |
# +-------------------------------+-------------------------------+
# |  COORDINATOR (0.2)            |  SESSION LOG (0.3)            |
# |  30% height                   |                               |
# +-------------------------------+-------------------------------+

set -euo pipefail

SESSION="bv"
LLAMA_ENDPOINT="${LLAMA_CPP_ENDPOINT:-http://petunia.home.lan:8001}"
PROJECT_ROOT="${BV_PROJECT_ROOT:-$HOME/workspace}"
BUILDER_DIR="$HOME/.bv-logic/builder"
VERIFIER_DIR="$HOME/.bv-logic/verifier"
SESSIONS_DIR="$HOME/bv/sessions"

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

# --- Share auth with builder/verifier agent dirs ---
mkdir -p "$SESSIONS_DIR"
if [[ -f "$HOME/.pi/agent/auth.json" ]]; then
  ln -sf "$HOME/.pi/agent/auth.json" "$BUILDER_DIR/auth.json"
  ln -sf "$HOME/.pi/agent/auth.json" "$VERIFIER_DIR/auth.json"
  echo "[init] Auth linked to builder and verifier."
else
  echo "[warn] No auth found at ~/.pi/agent/auth.json."
  echo "       Run 'pi /login' first, then re-run this script."
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
tmux set-option -t "$SESSION" allow-rename off

# --- Create 4-pane 2x2 grid ---
# Split into left/right columns, then split each column into top/bottom.
# This guarantees a proper grid — each column is independently partitioned.

# Step 1: Split into left and right columns.
#   Before: pane 0 (full)
#   After:  pane 0 (left 50%), pane 1 (right 50%)
tmux split-window -h -t "$SESSION:0.0"

# Step 2: Split left column — builder (top 70%), coordinator (bottom 30%).
#   After:  pane 0 (top-left), pane 1 (right), pane 2 (bottom-left)
tmux split-window -v -p 30 -t "$SESSION:0.0"

# Step 3: Split right column — verifier (top 70%), session log (bottom 30%).
#   After:  pane 0 (TL), pane 1 (TR), pane 2 (BL), pane 3 (BR)
tmux split-window -v -p 30 -t "$SESSION:0.1"

# --- Label and launch each pane ---

# Pane 0 (top-left): Builder — Gemini via Pi
tmux select-pane -t "$SESSION:0.0" -T "BUILDER [Gemini]"
tmux send-keys -t "$SESSION:0.0" \
  "export PI_CODING_AGENT_DIR=$BUILDER_DIR && cd $PROJECT_ROOT && pi --session-dir $SESSIONS_DIR" Enter

# Pane 1 (top-right): Verifier — Qwen via Pi + local llama.cpp
tmux select-pane -t "$SESSION:0.1" -T "VERIFIER [Qwen]"
tmux send-keys -t "$SESSION:0.1" \
  "export PI_CODING_AGENT_DIR=$VERIFIER_DIR && cd $PROJECT_ROOT && pi --provider llama-cpp-local --model qwen3.6-35b-a3b-coding-agent-mtp-128k" Enter

# Pane 2 (bottom-left): Coordinator — where you run tasks
tmux select-pane -t "$SESSION:0.2" -T "COORDINATOR"
tmux send-keys -t "$SESSION:0.2" "cd ~/.bv-logic/orchestrator && clear && echo '
=== BV Coordinator ===
Project root: $PROJECT_ROOT
Run a task:   ./coordinator.sh path/to/task.md
Headless:     npm start -- --task \"description\"
'" Enter

# Pane 3 (bottom-right): Live session log — waits for files if none exist yet
tmux select-pane -t "$SESSION:0.3" -T "SESSION LOG"
tmux send-keys -t "$SESSION:0.3" \
  "echo '[log] Watching ~/bv/sessions/ for JSONL files...' && until ls ~/bv/sessions/*.jsonl >/dev/null 2>&1; do sleep 2; done && tail -F ~/bv/sessions/*.jsonl" Enter

# --- Focus coordinator pane (where the engineer types) ---
tmux select-pane -t "$SESSION:0.2"

echo ""
echo "BV layout ready. Attach with:"
echo "  tmux attach -t $SESSION"
echo ""
echo "Pane layout:"
echo "  0: BUILDER [Gemini]     1: VERIFIER [Qwen]"
echo "  2: COORDINATOR          3: SESSION LOG"
