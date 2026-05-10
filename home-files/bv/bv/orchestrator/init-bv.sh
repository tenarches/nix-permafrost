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

# Configure visual style for this session immediately
tmux set-option -t "$SESSION" pane-border-status top
tmux set-option -t "$SESSION" pane-border-format " #[fg=black,bg=cyan,bold] #T #[default] "
tmux set-option -t "$SESSION" pane-active-border-style fg=cyan
tmux set-option -t "$SESSION" pane-border-style fg=white

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
# Builder starts in workspace, loads logic from .bv-logic/builder
tmux select-pane -t "$SESSION:0.0" -T "BUILDER"
tmux send-keys -t "$SESSION:0.0" "export PI_CODING_AGENT_SETTINGS_DIR=~/.bv-logic/builder && cd ~/workspace && pi" Enter

# Verifier starts in workspace (read-only), loads logic from .bv-logic/verifier
tmux select-pane -t "$SESSION:0.2" -T "VERIFIER"
tmux send-keys -t "$SESSION:0.2" "export PI_CODING_AGENT_SETTINGS_DIR=~/.bv-logic/verifier && cd ~/workspace && pi" Enter

# Coordinator starts in its logic directory
tmux select-pane -t "$SESSION:0.1" -T "COORDINATOR"
tmux send-keys -t "$SESSION:0.1" "cd ~/.bv-logic/orchestrator && clear" Enter

# Log Watcher watches persistent data with persistent retry (-F)
tmux select-pane -t "$SESSION:0.3" -T "SESSION LOG"
tmux send-keys -t "$SESSION:0.3" "tail -F ~/bv/sessions/*.jsonl 2>/dev/null" Enter

# Focus the Coordinator pane as the default
tmux select-pane -t "$SESSION:0.1"

echo "BV Layout initialized. Attach with: tmux attach -t $SESSION"
