---
name: worktree-orchestrator
description: Explicit-only. Invoke ONLY when the user types `/worktree-orchestrator` or names this skill by name. Do NOT auto-match on phrases like "parallel", "worktree", "spawn workers", etc. — the user reaches for this deliberately.
---

# Worktree Orchestrator

Run up to 4 parallel `claude` workers, each in its own git worktree + tmux session, observable via a cmux split panel. Workers push lifecycle events; main drains them.

## Hard rules

1. **Spawn workers and the monitor in the SAME response.** `spawn-worker.sh × N` then `spawn-monitor.sh` immediately. A turn that ends with workers up but no monitor is a broken contract — the user is staring at a blank wall. Re-run `spawn-monitor.sh` whenever workers are added or removed.
2. **Concurrency cap = 4.** `spawn-worker.sh` enforces it. >4 tasks → rotation queue: spawn 4, on completion ask user before merging, then spawn next.
3. **Plan before spawning.** Show a table (task-id / scope / branch / initial prompt) and wait for user "go". Each task must be a single review-able PR with disjoint file scope; if scopes overlap, sequence them.
4. **Never auto-merge.** Each merge needs explicit user consent. Before merging, run `git diff --stat <base>..HEAD` in the worktree and check for scope drift.
5. **Drain events at the start of every user turn** (`drain-events.sh`). It's the canonical status channel; tmux pane capture is a fallback.

## Sizing (gate every task before adding to plan)

A worktree = one PR-sized change (~30 min – 3 hr, ~30K–250K worker tokens, 200–1000 diff lines).

- **Too small** (single bugfix, rename, lint, <30K tokens): handle in main session. Spawn cost (~5–10K tokens) exceeds savings.
- **Too large** (rewrite/migrate-everything, >400K tokens, mid-task decisions): split into PR-sized pieces, run via rotation queue.
- **Ambiguous scope / overlap with another task**: sequence or split.

If a task fails any of these, push back with the reason — don't silently add it.

## Workflow

### 1. Spawn (workers + monitor — same response)

```bash
~/.claude/skills/worktree-orchestrator/scripts/spawn-worker.sh \
  <repo-path> <task-id> <branch-name> [base-branch]
# ...one per task, then immediately:
~/.claude/skills/worktree-orchestrator/scripts/spawn-monitor.sh
```

Each worker gets a unique `CWO_SLOT` (1..4) exported into its env, used as a port offset. `spawn-monitor.sh` splits the caller's surface into a 2-column grid (1=single, 2=stacked, 3=2-top+wide-bottom, 4=2×2).

After ~3s claude boot, send the initial prompt:

```bash
~/.claude/skills/worktree-orchestrator/scripts/send-task.sh <task-id> "$(cat <<'EOF'
You are working in an isolated git worktree on task: <task-id>.
You may only modify files under: <allowed paths>.
Do not touch files outside this scope. If you need to, stop and report.

Your slot number is $CWO_SLOT (1..4). For ANY dev server / port binding
in this worktree (vite, next, api, storybook, etc.), bind to
base_port + $CWO_SLOT — e.g. 5173 → 5173+$CWO_SLOT, 4484 → 4484+$CWO_SLOT.
Update vite.config / next.config / package.json scripts / .env.local as
needed BEFORE starting any server.

If your task has independent sub-parts that can run concurrently
(multiple files to scaffold, independent searches, parallel edits with
no shared state), dispatch them in parallel — invoke
`superpowers:dispatching-parallel-agents`, or send multiple tool calls
in a single response. Workers default to sequential; tell them otherwise
when applicable.

When done, run: touch .worker-done
Then summarize what you changed in the chat.

Task: <detailed instructions>
EOF
)"
```

The port and parallel-dispatch lines are mandatory in the template, not boilerplate to drop.

### 2. Observe

`drain-events.sh` at every user turn. Event types: `stop` (idle), `prompt` (out-of-band user input), `notify` (often a permission prompt — needs attention), `session_start`. Don't dump raw events to the user; summarize.

`list-workers.sh` to see slots and `.worker-done` state. `check-status.sh <task-id>` to read raw pane text (debugging only).

### 3. Intervene

```bash
~/.claude/skills/worktree-orchestrator/scripts/send-task.sh <task-id> "Stop. Try X instead."
```

User can also `tmux attach -t cwo-<task-id>` directly.

### 4. Merge

After explicit user "go":

```bash
~/.claude/skills/worktree-orchestrator/scripts/merge-worker.sh <task-id> [--strategy merge|rebase] [--keep]
```

Default merges into base, kills tmux, removes worktree, frees the slot. On conflict: STOP, surface hunks, let user drive resolution.

### 5. Abort

```bash
~/.claude/skills/worktree-orchestrator/scripts/kill-worker.sh <task-id> [--keep-worktree]
```

## Scripts

All under `~/.claude/skills/worktree-orchestrator/scripts/`:

| script | purpose |
|---|---|
| `spawn-worker.sh` | worktree + branch + tmux session running `claude`; allocates `CWO_SLOT`; installs hooks |
| `spawn-monitor.sh` | cmux 2-column split panel (max 4 panes) on the caller surface |
| `send-task.sh` | inject prompt into a worker via tmux send-keys |
| `drain-events.sh` | print new lines from `events.jsonl` since last drain (`--peek` for non-advancing) |
| `list-workers.sh` | registered workers + slot + tmux liveness + `.worker-done` |
| `check-status.sh` | last 50 lines of a worker's pane (raw text fallback) |
| `merge-worker.sh` | merge branch back, clean up |
| `kill-worker.sh` | stop a worker, optionally remove worktree |
| `worker-hook.sh` | worker-side hook handler (auto-wired by spawn-worker) |
| `monitor.sh` / `attach-all.sh` | text status / one-window-per-worker (rarely needed; prefer spawn-monitor) |

State: `~/.claude/worktree-orchestrator/state/` — `workers.tsv` (registry), `events.jsonl`, `events.offset`.

## Conventions

- **task-id**: lowercase kebab-case, ≤24 chars, unique among live workers
- **tmux session**: `cwo-<task-id>`
- **worktree**: `<repo>/.claude/worktrees/<task-id>`
- **branch**: suggest `worker/<task-id>`
- **port**: `base + $CWO_SLOT`
