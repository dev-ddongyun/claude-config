---
name: worktree-orchestrator
description: Explicit-only. Invoke ONLY when the user types `/worktree-orchestrator` or names this skill by name. Do NOT auto-match on phrases like "parallel", "worktree", "spawn workers", etc. — the user reaches for this deliberately.
---

# Worktree Orchestrator

You orchestrate parallel Claude Code workers across isolated git worktrees. Each worker is a real, attachable `claude` session running in its own tmux session — the user can `tmux attach -t cwo-<task-id>` at any time to observe or give direct guidance.

## MANDATORY: spawn the monitor immediately after the first worker

**The monitor is not optional. Do not forget it.**

The instant you spawn the first worker, run `spawn-monitor.sh` in the SAME response — before sending any task, before doing anything else. Workers are headless tmux sessions; without the monitor the user is staring at a blank wall while you claim things are "running". That is unacceptable. The user must be able to see every worker's pane in real time so they can intervene.

Order of operations on every orchestration:
1. `spawn-worker.sh` for each task (batched in one response)
2. `spawn-monitor.sh` — in that same response, never deferred
3. Then `send-task.sh` with the initial prompts

If you ever spawn workers and a turn ends without the monitor up, you've broken the contract. When in doubt, re-run `spawn-monitor.sh` — it tears down stale panels and rebuilds. Same rule applies after spawning additional workers from the rotation queue: re-spawn the monitor so the new worker gets a pane.

## When to use

- User wants to parallelize multiple independent tasks across worktrees
- User wants to "spawn workers" / "분기해서 작업"
- A large task can be cleanly decomposed into parts that touch disjoint files

Do NOT use for:
- A single sequential task (just do it directly)
- Tasks with strong sequential dependencies (parallelism gives nothing)
- Tasks that all heavily edit the same files (merge hell)

## Concurrency cap (HARD LIMIT: 4)

**At most 4 workers run concurrently.** This matches the monitor's 2-column / max-4-pane layout — beyond 4 the user can no longer observe everything at once. `spawn-worker.sh` enforces the cap by counting live tmux sessions and refusing the 5th spawn.

If the user has more than 4 tasks, treat it as a **rotation queue**:

1. Spawn the first 4. Show the remaining tasks as "queued".
2. When a worker finishes (`.worker-done` exists or user confirms), present the diff and ask explicitly: "merge `<task-id>` to `<base>` and free the slot?"
3. On user "go", run `merge-worker.sh <task-id>` (or `kill-worker.sh` if abandoning). The slot is now free.
4. Spawn the next queued task. Repeat until the queue is empty.

Do NOT auto-merge. Each merge needs explicit user consent — the user is the gate, not a heuristic. If the user wants to inspect a worker's worktree before deciding, point them at `<repo>-worktrees/<task-id>/`.

If the user really wants more than 4 in flight, push back: explain that monitor visibility is the bottleneck and propose either reducing scope or running in waves. Do not silently raise the cap.

## Worktree sizing (decide BEFORE planning)

A worktree's job is one cohesive change a senior engineer would finish in **30 minutes to 2–3 hours** — roughly a **single review-able PR** (200–1000 diff lines, ~80K–250K worker tokens). Sizing controls whether parallelism actually pays for itself.

Before drafting the plan, classify each candidate task:

**✅ Right-sized — worktree it**
- Add an API endpoint + its service code + tests
- Refactor one module / one directory
- Build one UI page or flow (with its API integration)
- Migrate one provider / one isolated subsystem
- Anything that fits in a normal mid-size PR

**❌ Too small — handle in the main session, do NOT spawn**
- A single bug fix in 1–2 files
- A rename, import cleanup, lint fix
- A one-shot script
- Adding a single component with no dependencies
- Anything under ~30K worker tokens or ~50 diff lines

Spawn cost (claude boot + context transfer + monitor pane) is ~5–10K tokens of overhead by itself. If the task is smaller than the overhead, parallelization is a net loss.

**❌ Too large — split, then queue**
- "Rewrite the auth system"
- "Migrate the entire frontend"
- "Build the v2 engine"
- Anything over ~400K worker tokens, 2000+ diff lines, or with mid-task decision branches

Big tasks blow the worker's context window, and force user-in-the-loop decisions mid-flight (which workers handle badly). Split into PR-sized pieces and run them through the rotation queue. With 4 slots, one session can typically work through 8–12 PRs.

### 4-question gate before adding a task to the plan

1. **Single review-able PR?** No → split.
2. **File boundaries cleanly disjoint from other tasks?** No → sequence them, or redefine.
3. **Worker can finish from its initial prompt alone (no mid-task decisions)?** No → split, or keep in main session.
4. **Estimated work > 30K worker tokens?** No → main session, don't spawn.

If a task fails any of these, do not silently add it. Push back to the user with the reason and a proposed alternative (split / sequence / handle directly).

## Pre-spawn planning (REQUIRED — do not skip)

Before spawning anything, you MUST present a plan and get user approval. The plan must include:

1. **Task list**: each task gets a short kebab-case `task-id` (e.g. `add-auth`, `refactor-router`)
2. **File boundaries**: which files/directories each task is allowed to touch. Tasks must NOT overlap. If overlap is unavoidable, sequence them instead.
3. **Base branch**: usually current `HEAD`, sometimes `main`
4. **Branch naming**: e.g. `worker/add-auth`
5. **Initial prompt for each worker**: a self-contained instruction the worker can act on without further context

Show the plan as a table. Wait for user "go" before spawning.

## Conflict prevention (judgment-based, not enforced)

There is no programmatic gate that stops a worker from editing a file outside its declared scope. Conflict prevention rests on **your** judgment as the orchestrator. Specifically:

1. **At plan time**: when drafting the file-boundary table, if two tasks could plausibly touch the same file (e.g. both modify `apps/web/lib/i18n.ts`), flag it to the user and propose either (a) sequencing them or (b) splitting one task so scopes are disjoint. Don't silently let overlap into the plan.

2. **In each worker's initial prompt**: explicitly state the allowed paths and add "do not modify files outside this list — if you need to, stop and report instead." This is the worker's only fence; make it concrete.

3. **Before merging** (matters most): run `git -C <worktree> diff --stat <base>..HEAD` and check the file list against the worker's declared scope. If a worker touched files outside scope, **do not silently merge** — report the deviation to the user with the file list and ask how to handle it. Common cases:
   - Worker touched a shared file (e.g. lockfile, generated code) — usually safe to keep, but warn if another active worker also touched it.
   - Worker drifted into another worker's territory — surface the conflict, let user decide whether to revert those edits or coordinate.
   - Worker made unrelated cleanups — ask user if they want them in this PR or split out.

4. **At merge time**: if `merge-worker.sh` reports a git conflict, STOP. Don't auto-resolve. Show the conflicted hunks and ask the user to drive resolution (or to abort and have a worker fix things).

This is prompt-level discipline, not a sandbox. It works because you (the main Claude) are reading the events and the diffs — workers can't be trusted to police themselves.

## Tracking progress (mental model, not a dashboard)

There is no aggregated progress UI. You hold the state in your head, refreshed by `drain-events.sh` at the start of each user turn. What to keep tracked mentally:

- **Per active worker**: task-id, declared scope, current status (running / idle-after-stop / awaiting-permission / done), most recent event.
- **Queue**: tasks not yet spawned (waiting for a slot).
- **Completed**: tasks already merged or killed (don't re-spawn the same task-id).

When the user asks "어떻게 돼가?" or implicitly needs a status update, summarize the above in a few lines — don't dump raw events. Use `drain-events.sh` (push) as the primary signal, `check-status.sh` (pull pane text) only when you need to see what a worker actually rendered.

## Scripts (all live in this skill's `scripts/` dir)

Use absolute paths via `$HOME` — these scripts are designed to be invoked from anywhere.

```
~/.claude/skills/worktree-orchestrator/scripts/
├── spawn-worker.sh    Create worktree + branch + tmux session running claude.
│                       Also drops .claude/settings.local.json into the worktree
│                       so the worker pushes events via worker-hook.sh.
├── send-task.sh       Send instructions to a running worker
├── check-status.sh    Capture tmux pane content for a worker (raw text fallback)
├── list-workers.sh    Show all registered workers and their tmux liveness
├── kill-worker.sh     Stop a worker (kills tmux + optionally removes worktree)
├── merge-worker.sh    Merge a worker's branch back and clean up
├── spawn-monitor.sh   2-column cmux panel layout (max 4 workers) for visual
│                       observability — caller surface is the one that gets split.
├── monitor.sh         Compact text-only status view (one block, refresh every 2s)
├── attach-all.sh      Open one host window per worker (rarely better than
│                       spawn-monitor)
├── worker-hook.sh     Worker-side hook handler. Wired into each worker via
│                       its .claude/settings.local.json. Receives Claude Code
│                       hook payload on stdin, identifies the worker by cwd,
│                       and appends a structured event line to events.jsonl.
└── drain-events.sh    Main-side: print events.jsonl lines appended since the
                        last drain. Silent when nothing is new. Use --peek to
                        read without advancing the offset.
```

State files: `~/.claude/worktree-orchestrator/state/`
- `workers.tsv` — registry, one tab-separated line per worker. Read via `list-workers.sh`, never edit by hand.
- `events.jsonl` — append-only event log. Workers push, main drains.
- `events.offset` — byte offset of the last main-side drain.

## Event channel (push from workers → drain from main)

Each worker has Claude Code hooks installed automatically by `spawn-worker.sh`. When a worker fires `Stop` / `UserPromptSubmit` / `Notification` / `SessionStart`, `worker-hook.sh` writes a JSON line to `events.jsonl`:

```
{"ts":"2026-05-01T08:42:01Z","task_id":"add-auth","type":"stop","session_id":"..."}
{"ts":"2026-05-01T08:42:14Z","task_id":"add-auth","type":"prompt","prompt":"also add password reset"}
{"ts":"2026-05-01T08:42:33Z","task_id":"add-auth","type":"notify","message":"Permission required for Edit"}
```

Event types:
- `stop` — worker finished a turn (now idle, waiting). Strong signal that it might be ready to merge.
- `prompt` — user typed something directly into the worker (via `tmux attach` or send-task). Lets main know about out-of-band requests.
- `notify` — Claude Code sent a notification (often a permission prompt). User attention needed.
- `session_start` — worker booted.

When orchestrating, the main session should call `drain-events.sh` at the start of each user turn (or whenever it needs fresh status) instead of capturing tmux panes. This is the canonical channel — pane capture via `check-status.sh` is a fallback for when you need raw terminal text.

Prefer `drain-events.sh` over `check-status.sh` for routine status sync. Use `check-status.sh` only when you need to see what the worker actually rendered (e.g., debugging a stuck pane).

## Workflow

### 1. Spawn (workers + monitor — same response)

For each task in the approved plan, run spawn-worker. **In the same response**, also run spawn-monitor. Do not split these across turns.

```bash
~/.claude/skills/worktree-orchestrator/scripts/spawn-worker.sh \
  <repo-path> <task-id> <branch-name> [base-branch]
# ...one per task, then immediately:
~/.claude/skills/worktree-orchestrator/scripts/spawn-monitor.sh
```

This creates `<repo-path>/.claude/worktrees/<task-id>/`, a new branch, a tmux session named `cwo-<task-id>`, starts `claude` inside it, and (via spawn-monitor) splits the caller's surface into a 2-column grid showing every worker's pane live.

After ~3 seconds (claude needs to boot), send the initial prompt:

```bash
~/.claude/skills/worktree-orchestrator/scripts/send-task.sh <task-id> "$(cat <<'EOF'
You are working in an isolated git worktree on task: <task-id>.
You may only modify files under: <allowed paths>.
Do not touch files outside this scope.

If your task has independent sub-parts that can run concurrently (e.g.
multiple files to scaffold, independent searches, parallel edits with no
shared state), dispatch them in parallel — invoke the
`superpowers:dispatching-parallel-agents` skill, or send multiple tool
calls in a single response. Sequential execution of independent work is a
waste of wall time.

When done, run: touch .worker-done
Then summarize what you changed in the chat.

Task: <detailed instructions>
EOF
)"
```

The parallel-dispatch instruction is not boilerplate — include it whenever the task plausibly has independent sub-parts. Workers default to sequential execution unless told otherwise.

The `.worker-done` sentinel file is how the main session detects completion (check via `check-status.sh` or by `ls <worktree>/.worker-done`).

### 2. Monitor

**At the start of every user turn during orchestration, call `drain-events.sh`** to pick up new worker events (stop / prompt / notify) since the last drain. That is the canonical status channel — it is event-driven and far cheaper than tmux pane capture.

The visual monitor was already spawned in step 1 (it is mandatory, not optional). If you spawned new workers since then, re-run `spawn-monitor.sh` so the new pane appears — it tears down stale panels and rebuilds.

Layout templates by worker count:

| N | Layout |
|---|--------|
| 1 | single pane |
| 2 | top + bottom (stacked) |
| 3 | 2 on top, 1 wide on bottom |
| 4 | 2x2 grid |

Caveat to mention to the user: panes contain nested `tmux attach`. Default Ctrl-B is the inner worker's prefix; to send a tmux command to the OUTER monitor session, press Ctrl-B Ctrl-B then the key.

Use `attach-all.sh` only if the user explicitly asks for one host window per worker. spawn-monitor is the default.

Periodically, when the user asks for status or after meaningful elapsed time:

```bash
~/.claude/skills/worktree-orchestrator/scripts/list-workers.sh
~/.claude/skills/worktree-orchestrator/scripts/check-status.sh <task-id>   # last 50 lines of pane
```

A worker is "done" when: (a) `.worker-done` exists in its worktree, OR (b) the user says it's done. Don't merge based purely on pane heuristics — they're unreliable.

### 3. Intervene

If a worker is stuck or going wrong, the user can attach directly. You can also send a steering message:

```bash
~/.claude/skills/worktree-orchestrator/scripts/send-task.sh <task-id> "Stop. Reconsider X. Try Y instead."
```

### 4. Merge

After confirmation, for each completed worker:

```bash
~/.claude/skills/worktree-orchestrator/scripts/merge-worker.sh <task-id> [--strategy merge|rebase] [--keep]
```

Default: merge into the base branch, kill tmux, remove worktree, deregister. `--keep` preserves the worktree/session for inspection.

If merge conflicts: STOP. Report conflicts to the user. Do not auto-resolve unless explicitly asked.

### 5. Cleanup on failure / abort

```bash
~/.claude/skills/worktree-orchestrator/scripts/kill-worker.sh <task-id> [--keep-worktree]
```

## Conventions

- **task-id**: lowercase, kebab-case, ≤ 24 chars, unique across active workers
- **tmux session name**: always `cwo-<task-id>` (cwo = claude worktree orchestrator)
- **Worktree location**: `<repo-path>/.claude/worktrees/<task-id>` — under the project's `.claude/` dir (typically gitignored, so worktrees stay out of main-repo tracking)
- **Branch name**: caller decides; suggest `worker/<task-id>`

## Failure modes to watch for

- **`claude` CLI not on PATH inside tmux**: tmux inherits PATH, but if the user has a complex shell init, the worker may fail to launch. `check-status.sh` will show a "command not found" line within seconds.
- **Worktree path collision**: if `<repo>-worktrees/<task-id>` already exists, spawn fails. Use a different task-id or clean up first.
- **Branch already exists**: spawn-worker.sh will fail. Either pick a fresh branch or delete the old one first (warn the user — could contain unmerged work).
- **User on the same branch in main repo**: git refuses to create a worktree on a branch that's already checked out somewhere. Spawn fails — user must switch the main repo to a different branch.

## Example session

```
User: "OpenHive에 3가지 독립 기능 병렬로 추가해줘: i18n 키 정리, 로그 뷰어 페이지, settings export."

Claude:
  1. Presents a 3-row plan (task-ids, file scopes, branches, initial prompts)
  2. Waits for user "go"
  3. Runs spawn-worker.sh × 3
  4. Runs send-task.sh × 3 with initial prompts
  5. Reports: "3 workers running in tmux: cwo-i18n-cleanup, cwo-log-viewer, cwo-settings-export. Attach with `tmux attach -t <name>`."
  6. (later, on user request) check-status, merge-worker
```
