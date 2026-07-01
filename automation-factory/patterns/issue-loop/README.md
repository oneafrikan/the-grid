# Pattern: issue-loop

An autonomous agent that works a repo's GitHub issue backlog unattended, with an
automatic code review posted to each issue. Two modules that compose with **zero
glue** — the loop commits with `#N`, which is exactly what the hook watches for.

| Module | File | Role |
|--------|------|------|
| **1 — review hook** | `hooks/post-commit-review.sh` | PostToolUse(Bash) hook: on every `git commit`, runs a backgrounded `claude -p` review of the diff and posts it to issue `#N`. |
| **2 — loop prompt** | `loop-prompt.template.md` | A `/loop` prompt: pick an eligible issue → implement → **verify** → commit (`#N`) → push → close → repeat; self-paced, stops when the backlog is clear. |
| **wiring** | `setup.sh` + `.gitignore` | Regenerates the prompt instance and merges the hook into `.claude/settings.json` for the current machine. Idempotent — safe to re-run after a clone or repo move. |

**The composition:** Module 2's `git commit -m "… #N"` triggers Module 1. You get
implement-and-review on every iteration without wiring the two together.

## Instantiate it into a target repo

This is a *pattern* (the tailor's cut), not a running automation. To make a suit:

1. **Copy the whole pattern into a tracked `loop/` folder** in the target repo:
   `mkdir -p <target>/loop && cp -r hooks loop-prompt.template.md setup.sh .gitignore <target>/loop/`
   Do this even if `<target>/.claude/` is gitignored (a common Claude Code
   convention — see "Check gitignore before instantiating" below). `loop/` sits
   at the target repo's top level, outside `.claude/`, so it's tracked regardless
   of that repo's `.claude/` policy.
2. **Fill the hook placeholders** in `<target>/loop/hooks/post-commit-review.sh`:
   `{{GH_REPO}}`, `{{PROJECT_CONTEXT}}`, `{{REVIEW_FOCUS}}`.
3. **Fill `loop-prompt.template.md` placeholders** — all except `{{WORKING_DIR}}`:
   `{{GH_REPO}}`, `{{PROJECT_CONTEXT}}`, `{{VERIFY_CMD}}`, `{{ISSUE_LABEL}}`. These
   don't vary by machine, so bake them in now; leave `{{WORKING_DIR}}` for
   `setup.sh` to fill per machine.
4. **Add an `agent-ready` label** in the target repo and tag the issues you're
   happy to automate.
5. **Run `bash loop/setup.sh`** — regenerates `loop/loop-prompt.md` with this
   machine's absolute path baked in, makes the hook executable, and merges it
   into `<target>/.claude/settings.json` (creates the file if absent). Re-run
   this any time the repo clones or moves to a new machine.
6. **Write a short `loop/README.md`** in the target documenting the layout (the
   module table above is a good starting point) and noting that
   `bash loop/setup.sh` re-wires everything after a clone or move.
7. In Claude Code, run `/loop <the contents of loop/loop-prompt.md>`.

> v2's `instantiate.sh` (see Roadmap) will collapse steps 1-4 and 6 into one
> command; step 5 (`setup.sh`) already ships as part of this pattern today.

## Check gitignore before instantiating

Before dropping any generated or automation file into a target repo, check
whether its destination directory is gitignored there:

    git check-ignore -v <path>

`.claude/` is commonly gitignored — Claude Code local settings are frequently
excluded by convention. Copy a hook straight into `.claude/hooks/`, or bake a
value into `.claude/settings.json`, and it silently vanishes on the next clone
or repo move — the automation doesn't survive. Default instead to a top-level
**tracked** folder (`loop/`) for anything portable (hook script, prompt
template, setup script), and regenerate whatever's genuinely machine-specific
(absolute paths, credentials) with a small idempotent setup script rather than
hand-baking it into a committed file. `.claude/settings.json` itself can stay
gitignored — `setup.sh` re-derives its hook-wiring on demand, so nothing is lost.

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
- **Portable content lives in a tracked `loop/` folder, not `.claude/`.** The
  automation must survive a clone or a repo move (e.g. laptop → production
  server) — anything needed to regenerate it (hook script, prompt template,
  setup script) goes in a tracked folder. Only genuinely machine-specific wiring
  (absolute paths baked into `.claude/settings.json`) gets regenerated on
  demand by `setup.sh`, never hand-baked into a committed file. Discovered when
  instantiating into `gkwilderness/keyword-universe`, whose `.gitignore` has a
  blanket `.claude/` entry — a common convention that would otherwise have
  made the whole automation invisible to git.

## Roadmap (v2)

- **`instantiate.sh`** — one command to cut this pattern into a target repo
  (copy into `loop/` + placeholder-fill + label creation). `setup.sh` already
  ships today and covers the machine-specific regeneration half of this (was
  previously the "settings merge" step) — v2 only needs to automate the
  one-time copy/fill/label steps around it, folding part of this roadmap item
  forward now.
- **PR mode** — `{{INTEGRATION}}=pr`: work on a branch, open a PR (review fires on
  the PR), optional auto-merge when green. Safer than committing to `main`.
- **Actionable review** — next iteration reads the prior auto-review and fixes any
  critical findings before moving on (closes the quality loop).
- **Compose with `agent-factory`** — the *implement* step delegates to composed
  specialists (`backend-dev`, `frontend-dev`…), turning the loop into an
  orchestrator over the team. This is why both factories live in the-grid.
- **Least-privilege guidance** — branch protection + scoped `gh` token for
  unattended runs (pairs with the `careful` / `guard` skills).
