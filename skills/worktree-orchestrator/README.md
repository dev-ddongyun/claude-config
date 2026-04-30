# worktree-orchestrator

Run multiple Claude Code workers in parallel, each in its own git worktree + tmux session, orchestrated from a single main session.

This is an **explicit-only** skill — it does not auto-trigger. Invoke via `/worktree-orchestrator` or by naming it directly.

## What it does

- Spawns each worker as a real `claude` CLI inside its own tmux session that the user can `tmux attach` into
- Caps concurrency at **4 workers** (matches the 2-column visual monitor layout)
- Workers push lifecycle events (Stop / UserPromptSubmit / Notification / SessionStart) into a shared `events.jsonl` via Claude Code hooks → main session drains them on each turn instead of polling pane text
- Bigger task lists are handled as a **rotation queue**: when a worker finishes, the main session presents the diff, asks the user for merge consent, frees the slot, then spawns the next queued task
- Conflict prevention is **judgment-based** (file-boundary table at plan time, scope check before merge) — no programmatic sandbox

## Install

```bash
# clone or copy this repo's skill dir into your Claude Code skills location
cp -R skills/worktree-orchestrator ~/.claude/skills/
chmod +x ~/.claude/skills/worktree-orchestrator/scripts/*.sh
```

State files live at `~/.claude/worktree-orchestrator/state/` (auto-created on first use).

Requires: `claude` CLI on `PATH`, `tmux`, `git` ≥ 2.5 (worktree support), `python3`. The `spawn-monitor.sh` script also expects `cmux` (an Electron-based macOS multiplexer) — without it, you can still use the rest of the skill and observe via plain `tmux attach`.

## Files

```
SKILL.md                  Full operating manual (loaded when the skill is invoked)
scripts/
  spawn-worker.sh         Create worktree + branch + tmux session running claude
                          (also installs .claude/settings.local.json for hooks)
  send-task.sh            Send a prompt into a running worker
  check-status.sh         Capture worker tmux pane (raw text fallback)
  list-workers.sh         Show registered workers and tmux liveness
  kill-worker.sh          Stop a worker (kills tmux + optionally removes worktree)
  merge-worker.sh         Merge a worker's branch back and clean up
  spawn-monitor.sh        2-column cmux panel layout (max 4 workers)
  monitor.sh              Compact text-only status view (refreshes every 2s)
  attach-all.sh           Open one host window per worker
  worker-hook.sh          Worker-side: receives Claude Code hook payloads, appends
                          to shared events.jsonl. Wired in by spawn-worker.sh.
  drain-events.sh         Main-side: print events.jsonl lines since last drain.
                          Silent when nothing is new. Use --peek / --reset.
```

## Sizing guideline (TL;DR)

One worktree = one review-able PR. Aim for **30 min – 2/3 hr of work, ~80K–250K worker tokens, 200–1000 diff lines**.

- Smaller (single bug fix, rename, one component) → handle in main session, don't spawn (overhead > work)
- Larger (full subsystem rewrite, cross-cutting migration) → split into PR-sized pieces and run them through the rotation queue

See `SKILL.md` § "Worktree sizing" for the 4-question gate.

## Cost

Roughly **15% extra tokens** on top of running the same workers independently — main session pays for plan drafting, event drain, and merge-time diff inspection. Worst case ~30% if a lot of conflict diagnosis is needed. Often offset by not having to re-brief 4 separate sessions about the same project context.

## Why explicit-only?

Earlier the description had auto-trigger phrases (`"한꺼번에 병렬로"`, `"spawn workers"`, etc.). It turned out to be too easy to invoke unintentionally — orchestration carries non-trivial overhead and changes how the whole session behaves. The user should reach for it deliberately.

## See also

- `SKILL.md` — full operating manual (concurrency cap, event channel, conflict-prevention rules, rotation queue, sizing)
