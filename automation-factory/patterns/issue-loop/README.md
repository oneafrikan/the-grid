# Pattern: issue-loop

An autonomous agent that works a repo's GitHub issue backlog unattended, with an
automatic code review posted to each issue. Two modules that compose with **zero
glue** — the loop commits with `#N`, which is exactly what the hook watches for.

| Module | File | Role |
|--------|------|------|
| **1 — review hook** | `hooks/post-commit-review.sh` + `settings.snippet.json` | PostToolUse(Bash) hook: on every `git commit`, runs a backgrounded `claude -p` review of the diff and posts it to issue `#N`. |
| **2 — loop prompt** | `loop-prompt.md` | A `/loop` prompt: pick an eligible issue → implement → **verify** → commit (`#N`) → push → close → repeat; self-paced, stops when the backlog is clear. |

**The composition:** Module 2's `git commit -m "… #N"` triggers Module 1. You get
implement-and-review on every iteration without wiring the two together.

## Instantiate it into a target repo

This is a *pattern* (the tailor's cut), not a running automation. To make a suit:

1. **Copy the hook** into the target repo:
   `cp hooks/post-commit-review.sh <target>/.claude/hooks/ && chmod +x <target>/.claude/hooks/post-commit-review.sh`
2. **Fill the hook placeholders** (`{{GH_REPO}}`, `{{PROJECT_CONTEXT}}`, `{{REVIEW_FOCUS}}`).
3. **Wire the hook** — merge `settings.snippet.json` into `<target>/.claude/settings.json`, replacing `{{WORKING_DIR}}`.
4. **Add an `agent-ready` label** in the target repo and tag the issues you're happy to automate.
5. **Fill `loop-prompt.md`** placeholders (`{{GH_REPO}}`, `{{WORKING_DIR}}`, `{{PROJECT_CONTEXT}}`, `{{VERIFY_CMD}}`, `{{ISSUE_LABEL}}`).
6. In Claude Code, run `/loop <the filled prompt>`.

> v2 will replace steps 1-5 with `automation-factory/instantiate.sh` (see Roadmap).

## Why each decision was made

- **Label-gated selection (`agent-ready`), not "lowest open issue."** A human opts
  each issue into autonomous work. Without this gate the loop would attack
  design/judgment issues it can't actually resolve. Lowest-numbered *within the
  label* keeps picking deterministic.
- **Verify gate before commit.** The loop runs `{{VERIFY_CMD}}` and **never commits
  a red build**. On failure it tries to fix what it changed, else reverts and
  labels the issue `blocked`. This is the single biggest guard against an
  autonomous agent silently landing broken work.
- **Failure / ambiguity handling.** Under-specified issues get a comment + a
  `needs-human` label and are skipped — the loop never spins or guesses on
  judgment calls.
- **"Only the changes the issue requires."** Autonomous agents over-implement —
  refactoring adjacent code, adding unasked features. This keeps diffs minimal
  and reviewable.
- **Commit message carries `#N`.** Deliberately triggers the review hook, so the
  two modules compose without extra wiring. Also leaves a clean issue→commit trail.
- **Review runs backgrounded.** `( … ) &` detaches so Claude Code is never blocked
  waiting on a review.
- **Honest diff truncation.** Large diffs are capped for cost, but the review
  *says so* rather than silently under-reviewing.
- **Close with a comment + commit hash.** Human-readable audit trail: what was
  done, in which commit, in one line.
- **No fixed interval.** The loop self-paces via `ScheduleWakeup` — fast issues,
  short gaps; slow issues, longer. Beats a fixed poll that wastes cycles.

## Roadmap (v2)

- **`instantiate.sh`** — one command to cut this pattern into a target repo
  (copy + placeholder-fill + settings merge + label creation).
- **PR mode** — `{{INTEGRATION}}=pr`: work on a branch, open a PR (review fires on
  the PR), optional auto-merge when green. Safer than committing to `main`.
- **Actionable review** — next iteration reads the prior auto-review and fixes any
  critical findings before moving on (closes the quality loop).
- **Compose with `agent-factory`** — the *implement* step delegates to composed
  specialists (`backend-dev`, `frontend-dev`…), turning the loop into an
  orchestrator over the team. This is why both factories live in the-grid.
- **Least-privilege guidance** — branch protection + scoped `gh` token for
  unattended runs (pairs with the `careful` / `guard` skills).
