#!/usr/bin/env bash
set -euo pipefail

# Usage: attach-all.sh [--app terminal|iterm|ghostty]
# Opens a new terminal window per active worker, attaching to each tmux session.

# Default app: prefer Wave when running inside a Wave block (WAVETERM_JWT is set).
if [ -n "${WAVETERM_JWT:-}" ]; then
  APP="wave"
else
  APP="terminal"
fi

while [ "$#" -gt 0 ]; do
  case "$1" in
    --app) APP="$2"; shift 2;;
    --app=*) APP="${1#--app=}"; shift;;
    -h|--help) echo "Usage: $0 [--app terminal|iterm|ghostty|wave]" >&2; exit 0;;
    *) echo "Unexpected arg: $1" >&2; exit 64;;
  esac
done

STATE_FILE="$HOME/.claude/worktree-orchestrator/state/workers.tsv"
if [ ! -s "$STATE_FILE" ]; then
  echo "(no workers registered)"
  exit 0
fi

open_in_terminal_app() {
  local cmd="$1"
  osascript <<EOF
tell application "Terminal"
  activate
  do script "$cmd"
end tell
EOF
}

open_in_iterm() {
  local cmd="$1"
  osascript <<EOF
tell application "iTerm"
  activate
  create window with default profile
  tell current session of current window to write text "$cmd"
end tell
EOF
}

find_wsh() {
  if command -v wsh >/dev/null 2>&1; then
    command -v wsh
  elif [ -x "$HOME/Library/Application Support/waveterm/bin/wsh" ]; then
    echo "$HOME/Library/Application Support/waveterm/bin/wsh"
  elif [ -x "/Applications/Wave.app/Contents/Resources/app/bin/wsh" ]; then
    echo "/Applications/Wave.app/Contents/Resources/app/bin/wsh"
  fi
}

# Wave block-id registry: maps task-id -> wave block-id, so re-running attach-all
# replaces the old block instead of accumulating duplicates.
WAVE_REG="$HOME/.claude/worktree-orchestrator/state/wave-blocks.tsv"
mkdir -p "$(dirname "$WAVE_REG")"
touch "$WAVE_REG"

wave_lookup_block() {
  awk -F'\t' -v id="$1" '$1==id {print $2; exit}' "$WAVE_REG"
}

wave_save_block() {
  local task_id="$1" block_id="$2"
  local tmp; tmp="$(mktemp)"
  awk -F'\t' -v id="$task_id" '$1!=id' "$WAVE_REG" > "$tmp"
  printf '%s\t%s\n' "$task_id" "$block_id" >> "$tmp"
  mv "$tmp" "$WAVE_REG"
}

open_in_wave() {
  local cmd="$1" task_id="$2"
  local wsh_bin; wsh_bin="$(find_wsh)"
  if [ -z "$wsh_bin" ]; then
    echo "ERROR: 'wsh' not found. Open Wave once to install the CLI." >&2
    return 1
  fi

  # Delete any previously-created block for this task
  local prev; prev="$(wave_lookup_block "$task_id")"
  if [ -n "$prev" ]; then
    "$wsh_bin" deleteblock -b "$prev" >/dev/null 2>&1 || true
  fi

  # Create the new block; capture its block-id from wsh run output
  local out
  out="$("$wsh_bin" run -- bash -lc "$cmd" 2>&1 || true)"
  echo "$out"
  local new_id
  new_id="$(echo "$out" | grep -oE 'block:[a-f0-9-]+' | head -1)"
  if [ -n "$new_id" ]; then
    wave_save_block "$task_id" "$new_id"
  fi
}

open_in_ghostty() {
  local cmd="$1"
  # Ghostty: open a new window via 'open -na' and pass an init command via env
  # Simpler approach: use AppleScript-style 'tell System Events' to open new window then type
  # But Ghostty's CLI directly supports: ghostty -e <command>
  if command -v ghostty >/dev/null 2>&1; then
    ghostty -e "$cmd" >/dev/null 2>&1 &
  else
    open -na Ghostty --args -e "$cmd"
  fi
}

count=0
while IFS=$'\t' read -r TASK_ID REPO BRANCH BASE WORKTREE TMUX_SESSION STARTED; do
  [ -z "$TASK_ID" ] && continue
  if ! tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    echo "skip $TMUX_SESSION (dead)"
    continue
  fi
  CMD="tmux attach -t $TMUX_SESSION"
  case "$APP" in
    terminal) open_in_terminal_app "$CMD";;
    iterm)    open_in_iterm "$CMD";;
    ghostty)  open_in_ghostty "$CMD";;
    wave)     open_in_wave "$CMD" "$TASK_ID";;
    *) echo "unknown --app: $APP" >&2; exit 64;;
  esac
  echo "opened: $TMUX_SESSION -> $APP"
  count=$((count + 1))
  sleep 0.2
done < "$STATE_FILE"

echo ""
echo "$count window(s) opened in $APP."
