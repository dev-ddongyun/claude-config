#!/usr/bin/env bash
set -euo pipefail

# Usage: send-task.sh <task-id> <message>
#        send-task.sh <task-id> -      (read message from stdin)
# Sends a message into the worker's tmux session, followed by Enter.

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 <task-id> <message|->" >&2
  exit 64
fi

TASK_ID="$1"
MSG="$2"

if [ "$MSG" = "-" ]; then
  MSG="$(cat)"
fi

TMUX_SESSION="cwo-$TASK_ID"

if ! tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
  echo "ERROR: tmux session '$TMUX_SESSION' not found" >&2
  exit 65
fi

# Use load-buffer + paste-buffer so multi-line text comes in as a single paste
# (Claude Code TUI treats raw Enter inside multi-line input as a newline, not submit).
# After pasting, send a small delay then Enter to submit.
BUF_NAME="cwo-send-$$"
printf '%s' "$MSG" | tmux load-buffer -b "$BUF_NAME" -
tmux paste-buffer -b "$BUF_NAME" -t "$TMUX_SESSION" -d
sleep 0.4
tmux send-keys -t "$TMUX_SESSION" Enter

echo "SENT to $TMUX_SESSION (${#MSG} chars)"
