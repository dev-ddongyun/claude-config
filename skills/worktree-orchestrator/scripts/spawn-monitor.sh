#!/usr/bin/env bash
set -euo pipefail

STATE_FILE="$HOME/.claude/worktree-orchestrator/state/workers.tsv"
PANEL_STATE="$HOME/.claude/worktree-orchestrator/state/cmux-worker-panels.tsv"
mkdir -p "$(dirname "$PANEL_STATE")"
touch "$PANEL_STATE"

MAX_WORKERS=4
ATTACH_DELAY_SECONDS=0.5

CMUX_BIN="$(command -v cmux || true)"
if [ -z "$CMUX_BIN" ] && [ -x "/Applications/cmux.app/Contents/Resources/bin/cmux" ]; then
  CMUX_BIN="/Applications/cmux.app/Contents/Resources/bin/cmux"
fi
if [ -z "$CMUX_BIN" ]; then
  echo "ERROR: cmux CLI not found." >&2
  exit 1
fi

CALLER_SURFACE="$("$CMUX_BIN" identify | /usr/bin/python3 -c '
import json, sys
print(json.load(sys.stdin).get("caller", {}).get("surface_ref", ""))
')"

if [ -z "$CALLER_SURFACE" ]; then
  echo "ERROR: could not identify caller surface" >&2
  exit 1
fi

TEST_COUNT="${1:-}"
if [ -n "$TEST_COUNT" ] && ! [[ "$TEST_COUNT" =~ ^[0-9]+$ ]]; then
  echo "Usage: $0 [worker-count]" >&2
  exit 64
fi

# Close any panels left over from a previous run.
if [ -s "$PANEL_STATE" ]; then
  while IFS=$'\t' read -r _worker surface_ref; do
    [ -n "$surface_ref" ] && "$CMUX_BIN" close-surface --surface "$surface_ref" >/dev/null 2>&1 || true
  done < "$PANEL_STATE"
  : > "$PANEL_STATE"
fi

WORKERS=()
if [ -n "$TEST_COUNT" ]; then
  for ((i = 1; i <= TEST_COUNT; i++)); do
    WORKERS+=("__test_worker_$i")
  done
elif [ -s "$STATE_FILE" ]; then
  while IFS=$'\t' read -r _task_id _repo _branch _base _worktree tmux_session _started; do
    [ -z "$tmux_session" ] && continue
    if tmux has-session -t "$tmux_session" 2>/dev/null; then
      WORKERS+=("$tmux_session")
    fi
  done < "$STATE_FILE"
fi

N="${#WORKERS[@]}"
if [ "$N" -eq 0 ]; then
  "$CMUX_BIN" new-split right --surface "$CALLER_SURFACE"
  exit 0
fi
if [ "$N" -gt "$MAX_WORKERS" ]; then
  echo "WARNING: $N workers; only first $MAX_WORKERS are shown." >&2
  WORKERS=("${WORKERS[@]:0:MAX_WORKERS}")
  N="$MAX_WORKERS"
fi
if [ -z "$TEST_COUNT" ]; then
  for tmux_session in "${WORKERS[@]}"; do
    tmux set-option -t "$tmux_session" status off >/dev/null 2>&1 || true
  done
fi

split_surface() {
  local surface_ref="$1" direction="$2"
  "$CMUX_BIN" new-split "$direction" --surface "$surface_ref" \
    | awk '{for (i=1; i<=NF; i++) if ($i ~ /^surface:/) print $i}'
}

# Splits are anchored at the caller's surface. cmux takes space from the source
# surface only, so the caller column shrinks while the rest of the workspace
# stays untouched. We do NOT try to equalize across the whole workspace.
#
# Layout: 2 columns fixed for N >= 3; rows grow. When N is odd, the last left
# row spans full width (because no right counterpart was split off it).
# Build order matters — we MUST build the full LEFT chain before adding any
# RIGHT panes, so that RIGHT panes don't get squished by later down-splits.
#   N=3: [A0|B0] / [A1 wide]
#   N=4: [A0|B0] / [A1|B1]
#   N=5: [A0|B0] / [A1|B1] / [A2 wide]
#   N=6: [A0|B0] / [A1|B1] / [A2|B2]
# N=1,2 keep a single column.
PANES=()
case "$N" in
  1)
    A="$(split_surface "$CALLER_SURFACE" right)"
    PANES=("$A")
    ;;
  2)
    A="$(split_surface "$CALLER_SURFACE" right)"
    B="$(split_surface "$A" down)"
    PANES=("$A" "$B")
    ;;
  *)
    LEFT_ROWS=$(( (N + 1) / 2 ))
    RIGHT_ROWS=$(( N / 2 ))
    LEFT=()
    RIGHT=()
    # 1) LEFT chain first: A0 → A1 → A2 → ... (top to bottom)
    LEFT[0]="$(split_surface "$CALLER_SURFACE" right)"
    for ((r = 1; r < LEFT_ROWS; r++)); do
      LEFT[r]="$(split_surface "${LEFT[r - 1]}" down)"
    done
    # 2) RIGHT panes split off each LEFT row that has a counterpart.
    #    Rows beyond RIGHT_ROWS (the odd-N tail) stay full-width.
    for ((r = 0; r < RIGHT_ROWS; r++)); do
      RIGHT[r]="$(split_surface "${LEFT[r]}" right)"
    done
    # 3) Row-major flatten so workers fill left→right, top→bottom.
    for ((r = 0; r < LEFT_ROWS; r++)); do
      PANES+=("${LEFT[r]}")
      (( r < RIGHT_ROWS )) && PANES+=("${RIGHT[r]}")
    done
    ;;
esac

sleep "$ATTACH_DELAY_SECONDS"
for i in "${!WORKERS[@]}"; do
  tmux_session="${WORKERS[i]}"
  surface_ref="${PANES[i]}"
  printf '%s\t%s\n' "$tmux_session" "$surface_ref" >> "$PANEL_STATE"
  if [ -n "$TEST_COUNT" ]; then
    "$CMUX_BIN" send-panel --panel "$surface_ref" "echo test worker $((i + 1))/$N" >/dev/null 2>&1 || true
  else
    "$CMUX_BIN" send-panel --panel "$surface_ref" "tmux attach -t $tmux_session" >/dev/null 2>&1 || true
    "$CMUX_BIN" send-key-panel --panel "$surface_ref" Enter >/dev/null 2>&1 || true
  fi
done
