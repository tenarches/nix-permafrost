#!/usr/bin/env bash
# ~/bv/orchestrator/init-bv.sh
# Sets up the 4-pane layout for the Builder-Verifier workflow.

SESSION="bv"

if tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "Session $SESSION already exists. Attach with: tmux attach -t $SESSION"
  exit 0
fi

# Create session and first pane
tmux new-session -d -s "$SESSION" -n "workflow"
tmux rename-window -t "$SESSION:0" "coding"

# 1. Split vertically (Top/Bottom)
# 0.0 (Top), 0.1 (Bottom)
tmux split-window -v -t "$SESSION:0.0"

# 2. Split Top pane horizontally (Top-Left/Top-Right)
# 0.0 (Top-Left), 0.2 (Top-Right), 0.1 (Bottom)
tmux split-window -h -t "$SESSION:0.0"

# 3. Split Bottom pane horizontally (Bottom-Left/Bottom-Right)
# 0.0 (Top-Left), 0.2 (Top-Right), 0.1 (Bottom-Left), 0.3 (Bottom-Right)
tmux split-window -h -t "$SESSION:0.1"

# Layout Summary:
# +-------------------+-------------------+
# |  Builder (0.0)    |  Verifier (0.2)   |
# +-------------------+-------------------+
# |  Coordinator (0.1)|  Log Watcher (0.3)|
# +-------------------+-------------------+

# Start the agents in their panes
tmux send-keys -t "$SESSION:0.0" "cd ~/.bv-logic/builder && pi" Enter
tmux send-keys -t "$SESSION:0.2" "cd ~/.bv-logic/verifier && pi" Enter
tmux send-keys -t "$SESSION:0.1" "cd ~/.bv-logic/orchestrator && clear" Enter
tmux send-keys -t "$SESSION:0.3" "tail -f ~/bv/sessions/*.jsonl 2>/dev/null" Enter

echo "BV Layout initialized. Attach with: tmux attach -t $SESSION"
echo "Then run the coordinator in the bottom-left pane (0.1)."
