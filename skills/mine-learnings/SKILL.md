---
name: mine-learnings
description: >
  Mine project history — commits, docs, and logs — for durable technical
  learnings (recurring bugs, gotchas, decisions, workarounds) and write them
  into LEARNINGS.md, folding the highest-value ones as short rules into
  CLAUDE.md. Idempotent: every run rescans full history but dedupes against
  already-recorded (and already-rejected) learnings by content hash, so
  nothing is ever proposed or written twice. Use when the user asks to
  "extract learnings", "mine learnings from history", "update CLAUDE.md from
  project history", "bake learnings into CLAUDE.md", or invokes
  /mine-learnings. Works in any git repo — discovers whatever docs/logs
  conventions that repo actually uses (LOGS/, docs/, CHANGELOG.md, README.md,
  etc.) rather than assuming a fixed layout.
---

# mine-learnings

Turn project history into durable, reusable knowledge: a `LEARNINGS.md` file
of dated entries, with the highest-value ones folded as short rules into
`CLAUDE.md`. Idempotent — safe to run repeatedly; only genuinely new material
produces new entries.

## Process

1. **Locate repo root and existing files.** `git rev-parse --show-toplevel`,
   then check for an existing `CLAUDE.md` and `LEARNINGS.md` at that root. If
   `LEARNINGS.md` doesn't exist, it will be created in step 6 — don't create
   an empty stub up front.

2. **Read the hash ledger.** If `LEARNINGS.md` exists, parse its hidden
   ledger comments (see "LEARNINGS.md format" below) for both accepted
   hashes (entries already written) and rejected hashes (candidates the user
   declined on a previous run). Both sets are things to never re-propose.

3. **Gather history sources:**
   - `git log` — commit messages, favoring conventional-commit prefixes
     (`fix:`, `revert:`, `hotfix:`) and messages describing a workaround or
     root cause. Cap on large histories (e.g. since the last tag, or the
     last ~300 commits) and say so explicitly if capped — never silently
     truncate.
   - Repo docs: `README.md`, `CHANGELOG.md`, `docs/**/*.md`.
   - Repo logs/handoff dirs if present: `LOGS/`, `logs/`, `notes/`,
     `.claude/logs/` (check what actually exists — don't assume a name).
   - Existing `CLAUDE.md` content, so already-stated rules aren't re-derived
     as "new" learnings.

4. **Extract candidates.** Look for:
   - Recurring fix/revert patterns — the same file or module fixed more than
     once suggests a recurring bug worth naming.
   - Explicit markers in docs/logs: "gotcha", "lesson", "workaround",
     "note:", "important:", "caveat", "root cause".
   - Decisions recorded in handoff/context-style logs (a past session
     explaining *why* it chose an approach).

   For each candidate, compute a content hash of the normalized learning
   text. Drop any candidate whose hash is already in the accepted or
   rejected ledger before it goes any further — this is what makes reruns
   idempotent.

5. **Confirm with the user before writing anything.** Present the remaining
   new candidates via `AskUserQuestion`, batched a few at a time (approve /
   edit / reject each). Never write a candidate straight to disk without
   this step — `CLAUDE.md` and `LEARNINGS.md` are checked-in files the user
   reads and re-reads; unwanted entries are expensive to notice and remove.

6. **Write approved entries to `LEARNINGS.md`** — dated section, category,
   source reference (commit SHA or file path), the learning itself (what
   happened, why it matters, how to apply it), and its content hash so
   future runs recognize it. Create the file with a short header if it
   doesn't exist yet.

7. **Fold only the most durable/actionable approved learnings into
   `CLAUDE.md`** as short rules, each pointing back to its `LEARNINGS.md`
   entry (e.g. `- Never do X — see LEARNINGS.md#short-title.`). Leave
   lower-value or situational entries living only in `LEARNINGS.md`.

   **Model-routing learnings go to `docs/model-selection.md` instead.** If an
   approved learning is about *which model to use for which job* — a model that
   failed at a task class, a cheaper model that turned out good enough, a
   retry/turn-count observation, an actual measured cost — it belongs in that
   document's decision table or its "Known gaps" section, not buried in
   `LEARNINGS.md` as prose. That file exists to answer "which model for X", and
   lived experience is better evidence than a vendor benchmark. Still write the
   `LEARNINGS.md` entry (the hash ledger depends on it) — but also update
   `docs/model-selection.md` and say so in the step-9 summary.

   This matters most for the token-efficiency question that document flags as
   an open evidence gap: no published cross-model turns-to-completion study
   exists, so observations mined from real history here are the only data
   the-grid will ever have on it. Don't let them evaporate.

8. **Record rejected candidates' hashes** in `LEARNINGS.md`'s rejected
   ledger so they aren't re-proposed on the next run.

9. **Report a short summary**: N new entries written, M folded into
   `CLAUDE.md`, K rejected, L already-seen (no-op, skipped before the user
   ever saw them).

## Idempotency contract

Every run rescans full history — there's no watermark file to go stale or
drift from reality — but nothing is ever duplicated: a candidate's hash
being present in either ledger short-circuits it before it reaches the user.
Running the skill twice with no new history in between must report "0 new
candidates" and touch neither file.

## LEARNINGS.md format

```markdown
<!-- rejected-hashes: 4b2c9a11, 7de3f001 -->

# Learnings

## <short title> — 2026-07-01
<!-- learning-hash: 9f2a1c4b -->
**Category:** bugfix | gotcha | decision | convention
**Source:** commit 3a9f21c — or LOGS/2026-06-30-foo.md

<What happened, why it matters, how to apply it going forward.>
```

The rejected-hashes comment sits once at the top of the file. Each entry
carries its own `learning-hash` comment immediately under its heading.

## Notes

- If a repo has no docs/logs beyond git history, mine commits alone — don't
  treat a missing `LOGS/`/`docs/` as an error.
- If `LEARNINGS.md` would grow past a few hundred lines, suggest splitting
  by category or year to the user — don't do this unprompted.
- This skill never runs `git push`; writing local files is as far as it
  goes. Committing/pushing the result is a separate, explicit step.
