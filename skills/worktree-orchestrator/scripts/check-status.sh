#!/usr/bin/env bash
set -euo pipefail

# Usage: check-status.sh <task-id> [--lines N]
# Captures the last N lines of the worker's tmux pane (default 50).

LINES=50
TASK_ID=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --lines)
      LINES="$2"; shift 2;;
    --lines=*)
      LINES="${1#--lines=}"; shift;;
    -h|--help)
      echo "Usage: $0 <task-id> [--lines N]" >&2; exit 0;;
    *)
      if [ -z "$TASK_ID" ]; then TASK_ID="$1"; shift
      else echo "Unexpected arg: $1" >&2; exit 64; fi;;
  esac
done

if [ -z "$TASK_ID" ]; then
  echo "Usage: $0 <task-id> [--lines N]" >&2; exit 64
fi

TMUX_SESSION="cwo-$TASK_ID"

if ! tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
  echo "ERROR: tmux session '$TMUX_SESSION' not found" >&2
  exit 65
fi

# Look up worktree path to also report .worker-done sentinel
STATE_FILE="$HOME/.claude/worktree-orchestrator/state/workers.tsv"
WORKTREE_PATH="$(awk -F'\t' -v id="$TASK_ID" '$1==id {print $5}' "$STATE_FILE" 2>/dev/null || true)"

DONE_MARK="no"
if [ -n "$WORKTREE_PATH" ] && [ -f "$WORKTREE_PATH/.worker-done" ]; then
  DONE_MARK="yes"
fi

echo "=== $TMUX_SESSION (worker-done: $DONE_MARK) ==="
tmux capture-pane -t "$TMUX_SESSION" -p -S "-$LINES"
