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

## Usage

Copy the snippet section out of a `SKILL.md` into the target file. No installer yet.
