#!/usr/bin/env bash
set -euo pipefail

# Usage: kill-worker.sh <task-id> [--keep-worktree]
# Kills the tmux session and (by default) removes the worktree + deregisters.

KEEP_WORKTREE=0
TASK_ID=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --keep-worktree) KEEP_WORKTREE=1; shift;;
    -h|--help) echo "Usage: $0 <task-id> [--keep-worktree]" >&2; exit 0;;
    *) if [ -z "$TASK_ID" ]; then TASK_ID="$1"; shift
       else echo "Unexpected arg: $1" >&2; exit 64; fi;;
  esac
done

if [ -z "$TASK_ID" ]; then
  echo "Usage: $0 <task-id> [--keep-worktree]" >&2; exit 64
fi

STATE_FILE="$HOME/.claude/worktree-orchestrator/state/workers.tsv"
TMUX_SESSION="cwo-$TASK_ID"

ROW="$(awk -F'\t' -v id="$TASK_ID" '$1==id' "$STATE_FILE" 2>/dev/null || true)"
if [ -z "$ROW" ]; then
  echo "ERROR: task-id '$TASK_ID' not found in registry" >&2
  exit 65
fi

REPO_PATH="$(echo "$ROW" | awk -F'\t' '{print $2}')"
WORKTREE_PATH="$(echo "$ROW" | awk -F'\t' '{print $5}')"

if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
  tmux kill-session -t "$TMUX_SESSION"
  echo "killed tmux: $TMUX_SESSION"
else
  echo "tmux session already gone: $TMUX_SESSION"
fi

if [ "$KEEP_WORKTREE" -eq 0 ]; then
  if [ -d "$WORKTREE_PATH" ]; then
    git -C "$REPO_PATH" worktree remove --force "$WORKTREE_PATH" || rm -rf "$WORKTREE_PATH"
    echo "removed worktree: $WORKTREE_PATH"
  fi
  # Deregister
  TMP="$(mktemp)"
  awk -F'\t' -v id="$TASK_ID" '$1!=id' "$STATE_FILE" > "$TMP"
  mv "$TMP" "$STATE_FILE"
  echo "deregistered: $TASK_ID"
else
  echo "kept worktree: $WORKTREE_PATH (still in registry)"
fi
