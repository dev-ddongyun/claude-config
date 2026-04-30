#!/usr/bin/env bash
set -euo pipefail

# Usage: monitor.sh [--interval N] [--lines N]
# Continuously displays a compact summary of all workers in a single view.
# Designed for a small terminal block that monitors progress without attaching.

INTERVAL=2
TAIL_LINES=6
while [ "$#" -gt 0 ]; do
  case "$1" in
    --interval) INTERVAL="$2"; shift 2;;
    --interval=*) INTERVAL="${1#--interval=}"; shift;;
    --lines) TAIL_LINES="$2"; shift 2;;
    --lines=*) TAIL_LINES="${1#--lines=}"; shift;;
    -h|--help) echo "Usage: $0 [--interval N] [--lines N]" >&2; exit 0;;
    *) echo "Unexpected arg: $1" >&2; exit 64;;
  esac
done

STATE_FILE="$HOME/.claude/worktree-orchestrator/state/workers.tsv"

trap 'tput cnorm 2>/dev/null || true; exit 0' INT TERM
tput civis 2>/dev/null || true

while :; do
  clear
  printf '\033[1mWorktree Workers Monitor\033[0m   (every %ss, Ctrl-C to exit)\n' "$INTERVAL"
  printf '%s\n' "──────────────────────────────────────────────────────────"

  if [ ! -s "$STATE_FILE" ]; then
    echo "(no workers)"
  else
    while IFS=$'\t' read -r TASK_ID REPO BRANCH BASE WORKTREE TMUX_SESSION STARTED; do
      [ -z "$TASK_ID" ] && continue
      if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
        LIVE="\033[32malive\033[0m"
      else
        LIVE="\033[31mdead\033[0m "
      fi
      if [ -f "$WORKTREE/.worker-done" ]; then
        DONE="\033[32m✓ done\033[0m"
      else
        DONE="…working"
      fi
      printf '\033[1m▸ %-22s\033[0m  %b  %b\n' "$TASK_ID" "$LIVE" "$DONE"
      if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
        tmux capture-pane -t "$TMUX_SESSION" -p -S "-$TAIL_LINES" 2>/dev/null \
          | sed 's/^/    │ /' \
          | tail -n "$TAIL_LINES"
      fi
      echo ""
    done < "$STATE_FILE"
  fi

  sleep "$INTERVAL"
done
