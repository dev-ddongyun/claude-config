#!/usr/bin/env bash
set -euo pipefail

# Worker-side hook handler. Invoked by Claude Code hooks inside a worker
# session. Receives the hook payload on stdin, identifies the worker by its
# cwd, and appends a structured event line to the shared events.jsonl.
#
# Usage: worker-hook.sh <stop|prompt|notify|session_start>
#
# Designed to be silent: if cwd doesn't match a registered worker, exit 0
# without writing anything (so accidentally-installed hooks are no-ops).

EVENT_TYPE="${1:-}"
case "$EVENT_TYPE" in
  stop|prompt|notify|session_start) ;;
  *) echo "ERROR: unknown event type: $EVENT_TYPE" >&2; exit 64 ;;
esac

STATE_DIR="$HOME/.claude/worktree-orchestrator/state"
EVENTS_FILE="$STATE_DIR/events.jsonl"
WORKERS_FILE="$STATE_DIR/workers.tsv"
mkdir -p "$STATE_DIR"
touch "$EVENTS_FILE"

# Identify worker by matching $PWD against registered worktree paths.
CWD="$PWD"
TASK_ID=""
if [ -s "$WORKERS_FILE" ]; then
  TASK_ID="$(awk -F'\t' -v cwd="$CWD" '$5==cwd {print $1; exit}' "$WORKERS_FILE")"
fi
[ -z "$TASK_ID" ] && exit 0

# Read Claude Code hook payload from stdin (best-effort).
PAYLOAD=""
if [ ! -t 0 ]; then
  PAYLOAD="$(cat || true)"
fi

TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Build event JSON via python (handles escaping). Pull useful fields per type.
/usr/bin/python3 - "$TS" "$TASK_ID" "$EVENT_TYPE" "$PAYLOAD" <<'PY' >> "$EVENTS_FILE"
import json, sys
ts, task_id, etype, raw = sys.argv[1:5]
try:
    data = json.loads(raw) if raw.strip() else {}
except Exception:
    data = {}
event = {"ts": ts, "task_id": task_id, "type": etype}
if etype == "prompt":
    event["prompt"] = data.get("prompt", "")
elif etype == "notify":
    event["message"] = data.get("message", "")
elif etype == "stop":
    event["session_id"] = data.get("session_id", "")
elif etype == "session_start":
    event["source"] = data.get("source", "")
print(json.dumps(event, ensure_ascii=False), flush=True)
PY

exit 0
