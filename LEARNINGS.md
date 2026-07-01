<!-- rejected-hashes: -->

# Learnings

Durable lessons mined from the-grid's own history (commits, `LOGS/`, docs).
Generated and maintained by the `mine-learnings` skill — don't hand-edit the
hash comments, they're the dedup ledger that keeps reruns idempotent. The
highest-value entries here are also folded as short rules into `CLAUDE.md`.

## Cross-machine scripts must pin locale, not trust find/wc — 2026-07-01
<!-- learning-hash: 2ef9481d -->
**Category:** gotcha
**Source:** commits 57bbdf1, 9cb3aaa

`catalog.sh` broke twice from environment assumptions: (1) `find | wc -l`
swept up `agent-factory` + uninitialized library submodules, inflating the
skill count; (2) `sort -f` collated punctuation differently on macOS vs
Linux, producing spurious `SKILLS.md` diffs across machines. Fixed by
computing totals from an authoritative pre-pass (not a blind tree find)
and pinning every sort to `LC_ALL=C`.

Apply going forward: any script whose output is committed/diffed across
machines must pin locale explicitly and derive counts from a controlled
pass, not a raw filesystem sweep.

## Handoff output paths need machine-scoping and verified dir names — 2026-07-01
<!-- learning-hash: cf14e1e0 -->
**Category:** gotcha
**Source:** commits 379a798, 5c90351

The handoff skill was fixed twice for path assumptions: (1) unscoped
filenames collided when the same topic was handed off from two machines on
the same day — fixed by prefixing `hostname -s`; (2) a vault's log dir was
guessed as `__LOGS/` when it was actually `LOGS/` — fixed by checking
rather than assuming.

Apply going forward: any skill writing files that could run from multiple
machines must scope filenames by hostname, and must verify a target
directory name exists rather than assume it from a similar-looking
convention.

## Library submodules can churn and inflate curated counts — 2026-07-01
<!-- learning-hash: 31cb8aeb -->
**Category:** decision
**Source:** commit 048e7d4 (leoyeai removal, closes #8); related fix in 57bbdf1

`leoyeai` was removed entirely because it caused recurring `SKILLS.md`
churn — upstream changes to a community submodule kept producing noisy
diffs unrelated to the-grid's own work. Separately, `catalog.sh` was fixed
to exclude pure-library repos from the headline skill count so a large
community repo can't silently balloon the number.

Apply going forward: treat library-tier submodules as inherently noisy;
don't casually `git submodule update --remote` them without expecting diff
churn, and keep curated totals derived only from wired/root-owned skills.

## Agent instructions that must never be skipped need an explicit block — 2026-07-01
<!-- learning-hash: a8196121 -->
**Category:** convention
**Source:** LOGS/2026-06-29-guide-server-gh-triage-wiring-context.md

QA on the gh-triage composed agent found the LLM processed all 30 open
issues instead of skipping ones already handled — the skip rule was only
implied by step ordering, never stated as a hard requirement. Fix: added a
bold `HARD SKIP RULE:` block before classification, listing exactly which
state labels trigger a skip.

Apply going forward: when writing role/`SKILL.md` instructions for a rule
that must never be violated, state it as an explicit imperative block —
don't rely on step ordering or structure to imply it.

## zsh doesn't word-split unquoted $var like bash — 2026-07-01
<!-- learning-hash: 6015e9d0 -->
**Category:** gotcha
**Source:** LOGS/2026-06-18-context.md

Updating 15 submodules with `git submodule update --recursive -- $paths`
silently failed to split the path list, because the session's shell was
zsh, not bash — zsh doesn't word-split unquoted variables by default. Had
to rewrite as a zsh array (`"${(@f)...}"`) to pass the list correctly.

Apply going forward: don't write bash-style unquoted-`$var` splitting in
shell commands run interactively across Gareth's machines — check the
active shell first, or avoid relying on word-splitting at all (arrays /
explicit quoting).
