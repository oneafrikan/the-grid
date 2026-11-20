---
name: project-retrofit
description: Move an existing project's big CLAUDE.md, notes or TODO into the standard doc set without losing any text. Use for "retrofit this project", "split up this CLAUDE.md" or "migrate our notes to the standard docs".
---

# project-retrofit

You decide where each block of text goes. `retrofit.py` moves it verbatim and
proves nothing was lost. **Never retype, summarise or reword source text**, and
never hand-edit a destination to fix a coverage failure.

Script: `project-factory/scripts/retrofit.py` (beside `skills/`; resolve symlinks
with `cd -P`). Run it from the target repo root. Exit codes: 0 ok, 1 coverage
failure, 2 plan error or refusal (nothing written).

## Steps

1. `python3 <retrofit.py> survey .` (read-only). Ask the operator ONE short batch:
   which sources to migrate (default: CLAUDE.md and agent notes; README and TODO
   stay unless chosen), which optional docs to scaffold, anything off-limits.
   Stop and wait for the reply.
2. Scaffold what is missing: `bash <project-factory>/scripts/cut-project.sh --generic [--with a,b] .`
   (existing files are skipped, never overwritten).
3. `python3 <retrofit.py> blocks <source>`, read the source with line numbers, and
   write the plan (format and mapping guide: sections/mapping-guide.md). Every
   block is accounted for exactly once. Ambiguous means `unsorted`. Never guess,
   never drop.
4. Run `apply <plan>` (dry run; it validates anchors) and show the operator a
   SUMMARY TABLE: destination, block count, bytes, first-line previews. Wait for
   approval or edits. Never apply before approval.
5. `apply <plan> --yes`, then `check <plan> --report`. If check fails: stop, show
   the MISSING lines, fix the plan, re-run apply and check.
6. Write a SLIM replacement entry doc (under 60 lines; the scaffold CLAUDE.md
   shape: what this is, read-when table, session start) holding only pointers
   and facts the operator gave or the source states. Blocks marked `keep` must
   be in it verbatim: `retrofit.py keep <plan>` prints them. Dry-run
   `finalize <plan> --replace-with <file>`, show the operator, and run it with
   `--yes` only after approval. It archives the original to `docs/archive/` and
   prints the undo command.
7. `python3 scripts/map.py` then `python3 scripts/map.py --check`. Report: coverage
   numbers, UNSORTED.md block count, `<fill:` markers left, files changed. Commit
   only if the operator asks.

## Sections

- sections/mapping-guide.md: read when writing the plan in step 3.
- sections/plan-format.md: read when the script rejects a plan or you need the exact syntax.
