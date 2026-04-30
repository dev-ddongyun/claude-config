#!/usr/bin/env bash
set -euo pipefail

# Usage: list-workers.sh
# Lists registered workers and their tmux liveness + .worker-done state.

STATE_FILE="$HOME/.claude/worktree-orchestrator/state/workers.tsv"

if [ ! -s "$STATE_FILE" ]; then
  echo "(no workers registered)"
  exit 0
fi

printf "%-20s %-4s %-30s %-12s %-10s %s\n" "TASK_ID" "SLOT" "BRANCH" "TMUX" "DONE" "WORKTREE"
printf "%-20s %-4s %-30s %-12s %-10s %s\n" "-------" "----" "------" "----" "----" "--------"

while IFS=$'\t' read -r TASK_ID REPO BRANCH BASE WORKTREE TMUX_SESSION STARTED SLOT _rest; do
  [ -z "$TASK_ID" ] && continue
  if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    LIVE="alive"
  else
    LIVE="dead"
  fi
  if [ -f "$WORKTREE/.worker-done" ]; then
    DONE="yes"
  else
    DONE="no"
  fi
  printf "%-20s %-4s %-30s %-12s %-10s %s\n" "$TASK_ID" "${SLOT:--}" "$BRANCH" "$LIVE" "$DONE" "$WORKTREE"
done < "$STATE_FILE"
