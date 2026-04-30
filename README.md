# claude-config

Reusable skills, snippets, and configs for Claude Code (and friends).

## Layout

```
skills/<skill-name>/SKILL.md
```

Each skill is a self-contained directory with a `SKILL.md` (frontmatter `name` + `description`, then body).

## Catalog

| Skill | What |
|---|---|
| [andrej-karpathy-guidelines](skills/andrej-karpathy-guidelines/SKILL.md) | 4-line "Working Principles" header for project `CLAUDE.md`. Fills the gaps Claude Code's default system prompt leaves (assumption-stating, push-back, goal-driven decomposition). |
| [worktree-orchestrator](skills/worktree-orchestrator/README.md) | Run up to 4 parallel Claude Code workers in isolated git worktrees + tmux sessions, with event-driven status push and a rotation queue for larger task lists. Explicit-only invocation. |

## Usage

Copy the snippet section out of a `SKILL.md` into the target file. No installer yet.
