# Karpathy Working Principles

Drop the block below at the top of a project `CLAUDE.md`. Compressed from Karpathy's 4-rule set; rules 2 (Simplicity) and 3 (Surgical) are omitted because Claude Code's default system prompt already enforces them. Rules 1 (Think Before Coding) and 4 (Goal-Driven Execution) are NOT in the default system prompt — those are the unique value here.

## Snippet

```markdown
## Working Principles (Karpathy)

- State assumptions explicitly. If multiple interpretations exist, surface them — don't pick silently. If something is unclear, stop and ask.
- Push back when warranted. If the user's ask has a flaw or a simpler path exists, say so — don't just comply.
- Convert imperative tasks ("add X", "fix Y") into verifiable goals (test that fails → make it pass; tests green before AND after refactor).
- For multi-step work, decompose as `1. step → verify: check` and execute step by step.
```

## Mapping to original 4 rules

| Original | Covered by |
|---|---|
| 1. Think Before Coding | lines 1–2 of snippet |
| 2. Simplicity First | Claude Code default system prompt |
| 3. Surgical Changes | Claude Code default system prompt |
| 4. Goal-Driven Execution | lines 3–4 of snippet |

## Source

Adapted from a Karpathy-style 65-line `CLAUDE.md` template. Full text emphasized "minimum code", "touch only what you must", "no abstractions for single-use code" — all of which Claude Code already enforces. Compressing to 4 lines keeps the unique value without redundant noise.
