#!/usr/bin/env bash
set -euo pipefail

# Usage: merge-worker.sh <task-id> [--strategy merge|rebase] [--keep] [--into <branch>]
# Merges the worker's branch into <base-branch> (or --into target). Then cleans up by default.

STRATEGY="merge"
KEEP=0
INTO=""
TASK_ID=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --strategy) STRATEGY="$2"; shift 2;;
    --strategy=*) STRATEGY="${1#--strategy=}"; shift;;
    --keep) KEEP=1; shift;;
    --into) INTO="$2"; shift 2;;
    --into=*) INTO="${1#--into=}"; shift;;
    -h|--help) echo "Usage: $0 <task-id> [--strategy merge|rebase] [--keep] [--into <branch>]" >&2; exit 0;;
    *) if [ -z "$TASK_ID" ]; then TASK_ID="$1"; shift
       else echo "Unexpected arg: $1" >&2; exit 64; fi;;
  esac
done

if [ -z "$TASK_ID" ]; then
  echo "Usage: $0 <task-id> [--strategy merge|rebase] [--keep] [--into <branch>]" >&2; exit 64
fi
case "$STRATEGY" in merge|rebase) ;; *) echo "ERROR: --strategy must be merge|rebase" >&2; exit 64;; esac

STATE_FILE="$HOME/.claude/worktree-orchestrator/state/workers.tsv"
TMUX_SESSION="cwo-$TASK_ID"

ROW="$(awk -F'\t' -v id="$TASK_ID" '$1==id' "$STATE_FILE" 2>/dev/null || true)"
if [ -z "$ROW" ]; then
  echo "ERROR: task-id '$TASK_ID' not found in registry" >&2
  exit 65
fi

REPO_PATH="$(echo "$ROW" | awk -F'\t' '{print $2}')"
BRANCH="$(echo "$ROW" | awk -F'\t' '{print $3}')"
BASE="$(echo "$ROW" | awk -F'\t' '{print $4}')"
WORKTREE_PATH="$(echo "$ROW" | awk -F'\t' '{print $5}')"
TARGET="${INTO:-$BASE}"

# Warn if tmux session is still alive
if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
  echo "WARNING: worker tmux session '$TMUX_SESSION' is still alive."
  echo "         Make sure the worker has stopped editing files before merging."
fi

# Sanity: worktree clean?
if [ -n "$(git -C "$WORKTREE_PATH" status --porcelain)" ]; then
  echo "ERROR: worktree has uncommitted changes — commit or stash first:"
  git -C "$WORKTREE_PATH" status --short
  exit 66
fi

# Switch the main repo to TARGET (without disturbing the worktree)
CURRENT_IN_MAIN="$(git -C "$REPO_PATH" rev-parse --abbrev-ref HEAD)"
if [ "$CURRENT_IN_MAIN" != "$TARGET" ]; then
  echo ">>> git -C $REPO_PATH checkout $TARGET"
  git -C "$REPO_PATH" checkout "$TARGET"
fi

echo ">>> $STRATEGY $BRANCH into $TARGET"
if [ "$STRATEGY" = "merge" ]; then
  if ! git -C "$REPO_PATH" merge --no-ff "$BRANCH"; then
    echo ""
    echo "MERGE CONFLICT. Resolve in $REPO_PATH then re-run with --keep, or abort with: git -C $REPO_PATH merge --abort"
    exit 67
  fi
else
  # Rebase strategy: replay branch commits onto target
  if ! git -C "$WORKTREE_PATH" rebase "$TARGET"; then
    echo "REBASE CONFLICT in $WORKTREE_PATH. Resolve, then re-run merge-worker.sh."
    exit 67
  fi
  git -C "$REPO_PATH" merge --ff-only "$BRANCH"
fi

echo "merged: $BRANCH -> $TARGET"

if [ "$KEEP" -eq 1 ]; then
  echo "kept worktree: $WORKTREE_PATH (still in registry, tmux session may still be alive)"
  exit 0
fi

# Cleanup: kill tmux, remove worktree, delete branch, deregister
if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
  tmux kill-session -t "$TMUX_SESSION"
  echo "killed tmux: $TMUX_SESSION"
fi

if [ -d "$WORKTREE_PATH" ]; then
  git -C "$REPO_PATH" worktree remove --force "$WORKTREE_PATH" || rm -rf "$WORKTREE_PATH"
  echo "removed worktree: $WORKTREE_PATH"
fi

if git -C "$REPO_PATH" rev-parse --verify "$BRANCH" >/dev/null 2>&1; then
  git -C "$REPO_PATH" branch -d "$BRANCH" 2>/dev/null || \
    echo "(branch '$BRANCH' not deleted — may be unmerged elsewhere; delete manually if intended)"
fi

TMP="$(mktemp)"
awk -F'\t' -v id="$TASK_ID" '$1!=id' "$STATE_FILE" > "$TMP"
mv "$TMP" "$STATE_FILE"
echo "deregistered: $TASK_ID"
