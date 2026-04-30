#!/usr/bin/env bash
set -euo pipefail

# Main-side: print events.jsonl lines that were appended since the last drain.
# Tracks the byte offset in state/events.offset so repeated calls only return
# new entries. Silent (exit 0, no output) when there's nothing new.
#
# Usage:
#   drain-events.sh           # print new events, advance offset
#   drain-events.sh --peek    # print new events, do NOT advance offset
#   drain-events.sh --reset   # discard offset (next call returns everything)

STATE_DIR="$HOME/.claude/worktree-orchestrator/state"
EVENTS_FILE="$STATE_DIR/events.jsonl"
OFFSET_FILE="$STATE_DIR/events.offset"
mkdir -p "$STATE_DIR"
touch "$EVENTS_FILE"

PEEK=0
RESET=0
for arg in "$@"; do
  case "$arg" in
    --peek)  PEEK=1 ;;
    --reset) RESET=1 ;;
    -h|--help)
      sed -n '4,12p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $arg" >&2; exit 64 ;;
  esac
done

if [ "$RESET" -eq 1 ]; then
  rm -f "$OFFSET_FILE"
  exit 0
fi

OFFSET=0
[ -f "$OFFSET_FILE" ] && OFFSET="$(cat "$OFFSET_FILE" 2>/dev/null || echo 0)"
case "$OFFSET" in ''|*[!0-9]*) OFFSET=0 ;; esac

SIZE="$(wc -c < "$EVENTS_FILE" | tr -d ' ')"

# File rotated/truncated → reset offset.
if [ "$OFFSET" -gt "$SIZE" ]; then OFFSET=0; fi

if [ "$SIZE" -le "$OFFSET" ]; then
  exit 0
fi

dd if="$EVENTS_FILE" bs=1 skip="$OFFSET" count=$(( SIZE - OFFSET )) 2>/dev/null

if [ "$PEEK" -eq 0 ]; then
  echo "$SIZE" > "$OFFSET_FILE"
fi
