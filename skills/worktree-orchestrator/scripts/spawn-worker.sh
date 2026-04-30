#!/usr/bin/env bash
set -euo pipefail

# Usage: spawn-worker.sh <repo-path> <task-id> <branch-name> [base-branch]
# Creates a git worktree, a new branch, and a tmux session running `claude` inside.

if [ "$#" -lt 3 ] || [ "$#" -gt 4 ]; then
  echo "Usage: $0 <repo-path> <task-id> <branch-name> [base-branch]" >&2
  exit 64
fi

REPO_PATH="$(cd "$1" && pwd)"
TASK_ID="$2"
BRANCH="$3"
BASE_BRANCH="${4:-}"

STATE_DIR="$HOME/.claude/worktree-orchestrator/state"
STATE_FILE="$STATE_DIR/workers.tsv"
mkdir -p "$STATE_DIR"
touch "$STATE_FILE"

# Validate task-id (kebab-case, <=24 chars)
if ! [[ "$TASK_ID" =~ ^[a-z0-9]([a-z0-9-]{0,22}[a-z0-9])?$ ]]; then
  echo "ERROR: task-id must be lowercase kebab-case, <=24 chars: $TASK_ID" >&2
  exit 65
fi

# Check duplicate task-id
if awk -F'\t' -v id="$TASK_ID" '$1==id {found=1} END{exit !found}' "$STATE_FILE"; then
  echo "ERROR: task-id '$TASK_ID' is already registered. Use list-workers.sh / kill-worker.sh first." >&2
  exit 66
fi

# Concurrency cap: matches spawn-monitor.sh display limit. Count workers whose
# tmux session is alive — dead rows don't count toward the cap.
# Slot allocation: each worker gets a unique slot in [1..MAX_CONCURRENT] used
# as a port offset (CWO_SLOT). Reuses the lowest free slot among live rows.
MAX_CONCURRENT=4
ALIVE=0
USED_SLOTS=""
while IFS=$'\t' read -r _id _repo _branch _base _worktree tmux_session _started slot _rest; do
  [ -z "$tmux_session" ] && continue
  if tmux has-session -t "$tmux_session" 2>/dev/null; then
    ALIVE=$((ALIVE + 1))
    [ -n "$slot" ] && USED_SLOTS="$USED_SLOTS $slot "
  fi
done < "$STATE_FILE"
if [ "$ALIVE" -ge "$MAX_CONCURRENT" ]; then
  echo "ERROR: $ALIVE workers already running (cap=$MAX_CONCURRENT)." >&2
  echo "       Free a slot with merge-worker.sh or kill-worker.sh first." >&2
  exit 71
fi

SLOT=""
for n in $(seq 1 "$MAX_CONCURRENT"); do
  case "$USED_SLOTS" in
    *" $n "*) ;;
    *) SLOT="$n"; break ;;
  esac
done
if [ -z "$SLOT" ]; then
  echo "ERROR: no free slot (this should not happen — cap check above failed)" >&2
  exit 72
fi

# Validate repo
if ! git -C "$REPO_PATH" rev-parse --git-dir >/dev/null 2>&1; then
  echo "ERROR: $REPO_PATH is not a git repository" >&2
  exit 67
fi

# Resolve base branch
if [ -z "$BASE_BRANCH" ]; then
  BASE_BRANCH="$(git -C "$REPO_PATH" rev-parse --abbrev-ref HEAD)"
fi

# Compute worktree path: <repo>/.claude/worktrees/<task-id>
# Living under .claude/ means the project's .gitignore (which typically excludes
# .claude/) keeps worktrees out of the main repo's tracking automatically.
WORKTREE_PARENT="$REPO_PATH/.claude/worktrees"
WORKTREE_PATH="$WORKTREE_PARENT/$TASK_ID"
mkdir -p "$WORKTREE_PARENT"

if [ -e "$WORKTREE_PATH" ]; then
  echo "ERROR: worktree path already exists: $WORKTREE_PATH" >&2
  exit 68
fi

# Create worktree + branch
echo ">>> git worktree add -b $BRANCH $WORKTREE_PATH $BASE_BRANCH"
git -C "$REPO_PATH" worktree add -b "$BRANCH" "$WORKTREE_PATH" "$BASE_BRANCH"

TMUX_SESSION="cwo-$TASK_ID"

# Make sure no stale tmux session of the same name exists
if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
  echo "ERROR: tmux session $TMUX_SESSION already exists" >&2
  git -C "$REPO_PATH" worktree remove --force "$WORKTREE_PATH" || true
  exit 69
fi

CLAUDE_BIN="$(command -v claude || true)"
if [ -z "$CLAUDE_BIN" ]; then
  echo "ERROR: 'claude' CLI not found on PATH" >&2
  git -C "$REPO_PATH" worktree remove --force "$WORKTREE_PATH" || true
  exit 70
fi

# Drop a settings.local.json that wires Claude Code hooks → worker-hook.sh.
# Each worker pushes lifecycle events (Stop / UserPromptSubmit / Notification /
# SessionStart) into the shared events.jsonl, which the main session drains.
WORKER_HOOK_SCRIPT="$HOME/.claude/skills/worktree-orchestrator/scripts/worker-hook.sh"
SETTINGS_DIR="$WORKTREE_PATH/.claude"
mkdir -p "$SETTINGS_DIR"
cat > "$SETTINGS_DIR/settings.local.json" <<JSON
{
  "hooks": {
    "Stop": [{"hooks": [{"type": "command", "command": "$WORKER_HOOK_SCRIPT stop"}]}],
    "UserPromptSubmit": [{"hooks": [{"type": "command", "command": "$WORKER_HOOK_SCRIPT prompt"}]}],
    "Notification": [{"hooks": [{"type": "command", "command": "$WORKER_HOOK_SCRIPT notify"}]}],
    "SessionStart": [{"hooks": [{"type": "command", "command": "$WORKER_HOOK_SCRIPT session_start"}]}]
  }
}
JSON

# Hide settings.local.json from git in this worktree (per-repo exclude is
# shared across worktrees, so this writes once and stays out of the diff).
GIT_COMMON_DIR="$(git -C "$WORKTREE_PATH" rev-parse --git-common-dir)"
if [ -n "$GIT_COMMON_DIR" ] && [ -d "$GIT_COMMON_DIR" ]; then
  EXCLUDE_FILE="$GIT_COMMON_DIR/info/exclude"
  mkdir -p "$(dirname "$EXCLUDE_FILE")"
  touch "$EXCLUDE_FILE"
  if ! grep -qxF '.claude/settings.local.json' "$EXCLUDE_FILE"; then
    printf '\n# worktree-orchestrator (cwo)\n.claude/settings.local.json\n' >> "$EXCLUDE_FILE"
  fi
fi

# Start a detached tmux session that cd's into the worktree and runs claude.
# CWO_SLOT is exported into the worker's shell so its dev servers can bind
# to (base_port + CWO_SLOT) and avoid colliding with the main repo or with
# other live workers.
tmux new-session -d -s "$TMUX_SESSION" -c "$WORKTREE_PATH" \
  -e "CWO_SLOT=$SLOT" -e "CWO_TASK_ID=$TASK_ID" "$CLAUDE_BIN"

# Register (slot appended as 8th column; older readers ignore trailing fields)
NOW="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$TASK_ID" "$REPO_PATH" "$BRANCH" "$BASE_BRANCH" "$WORKTREE_PATH" "$TMUX_SESSION" "$NOW" "$SLOT" \
  >> "$STATE_FILE"

cat <<EOF
SPAWNED: $TASK_ID
  worktree:    $WORKTREE_PATH
  branch:      $BRANCH (from $BASE_BRANCH)
  tmux:        $TMUX_SESSION
  slot:        $SLOT  (CWO_SLOT — add this to all dev server ports)
  attach:      tmux attach -t $TMUX_SESSION
  detach:      Ctrl-B then D

Note: claude takes ~2-3 seconds to boot. Wait briefly before sending tasks.
EOF
