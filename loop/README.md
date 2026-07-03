# loop/ — issue-loop automation (instantiated)

Cut from `automation-factory/patterns/issue-loop` on 2026-07-03. An autonomous
agent that works this repo's `ready-for-agent` issue backlog unattended, with an
automatic code review posted to each issue.

| Module | File | Role |
|--------|------|------|
| **1 — review hook** | `hooks/post-commit-review.sh` | PostToolUse(Bash) hook: on every `git commit`, runs a backgrounded `claude -p` review of the diff and posts it to issue `#N`. |
| **2 — loop prompt** | `loop-prompt.template.md` → `loop-prompt.md` (generated) | The `/loop` prompt: pick the lowest `ready-for-agent` issue → implement → verify (bats) → commit (`#N`) → push → close → repeat. Self-paced; stops when the backlog is clear. |
| **wiring** | `setup.sh` | Bakes this machine's absolute path into `loop-prompt.md` and merges the hook into `.claude/settings.json`. Idempotent. |

## This repo's parameters

- **Issue label:** `ready-for-agent` (opt-in gate — a human tags each issue the loop may work)
- **Verify gate:** `tests/lib/bats-core/bin/bats tests/` — the loop never commits a red suite
- **Escape labels:** `needs-human` (ambiguous issue, skipped) / `blocked` (verify failed, reverted)

## Run it

```bash
bash loop/setup.sh   # after any clone or repo move — regenerates machine wiring
```

Then in Claude Code: `/loop` with the contents of `loop/loop-prompt.md`.

## Notes

- `loop-prompt.md` is generated (absolute path baked in) and gitignored here;
  `loop-prompt.template.md` is the tracked source.
- `.claude/settings.json` is gitignored (machine-specific hook path) —
  `setup.sh` re-derives it, nothing is lost on clone.
