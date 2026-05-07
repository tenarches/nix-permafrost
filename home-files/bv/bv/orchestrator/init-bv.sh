#!/usr/bin/env bash
# ~/bv/orchestrator/init-bv.sh
# Sets up the 4-pane layout for the Builder-Verifier workflow.

SESSION="bv"

if tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "Session $SESSION already exists. Attach with: tmux attach -t $SESSION"
  exit 0
fi

# Create session and first pane (Builder)
tmux new-session -d -s "$SESSION" -n "workflow"
tmux rename-window -t "$SESSION:0" "coding"

# Split horizontally for Verifier (Pane 2)
tmux split-window -h -t "$SESSION:0.0"

# Split Pane 0 vertically for Coordinator (Pane 1)
tmux split-window -v -t "$SESSION:0.0"

# Split Pane 1 horizontally for Log Watcher (Pane 3)
tmux split-window -h -t "$SESSION:0.1"

# Layout:
# +---------+---------+
# | Builder | Verifier|
# | (0.0)   | (0.2)   |
# +---------+---------+
# | Coord   | Log     |
# | (0.1)   | (0.3)   |
# +---------+---------+

# Start the agents in their panes
tmux send-keys -t "$SESSION:0.0" "pi" Enter
tmux send-keys -t "$SESSION:0.2" "pi" Enter
tmux send-keys -t "$SESSION:0.1" "cd ~/bv/orchestrator && clear" Enter
tmux send-keys -t "$SESSION:0.3" "tail -f ~/bv/sessions/*.jsonl 2>/dev/null" Enter

echo "BV Layout initialized. Attach with: tmux attach -t $SESSION"
echo "Then run the coordinator in Pane 1 (bottom-left)."
