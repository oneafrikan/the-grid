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
**Source:** LOGS/2026-06-29-<host>-gh-triage-wiring-context.md

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

## Claude Desktop surfaces differ: Code tab = ~/.claude; Cowork = plugins only, cloud subagents with staging — 2026-11-05
<!-- learning-hash: b5c294e1 -->
**Category:** gotcha
**Source:** docs/business-tier/DELEGATION-GATE.md (Results), docs/business-tier/DECISIONS.md (ADR-008), INSTALL.md

The Desktop app has two surfaces that wire differently. The Code tab runs Claude
Code and reads the wired `~/.claude` (bare agent names, local folder visible).
Cowork ignores `~/.claude`: it sees only plugins installed in Cowork, plugin agents
are not listed but resolve by namespaced name, and subagents run in a cloud
container on files the main session stages in and writes back (originals replaced
in place).

Apply going forward: install per surface (INSTALL.md), send git and worktree work
to the Code tab, and warn anyone using Cowork on a folder to keep it under git or
backed up. Cowork details are self-reported from one run.

## Reconciling local branches after an upstream history rewrite — 2026-11-05
<!-- learning-hash: 0c0f792d -->
**Category:** gotcha
**Source:** session of 2026-11-05 (origin/main force-rewritten)

On 2026-11-05 `origin/main` was force-rewritten with an identical tree and new
SHAs. `git cherry` / patch-id reported false "unmerged" commits because the
rewrite altered early commits. The reliable check was
`git rev-list --count <old-main>..<branch>` against the pre-rewrite main SHA
(from the reflog), plus a subject match against the new main. The fix was
`git reset --hard origin/main`, never a pull or merge of the two histories.

Apply going forward: after an upstream history rewrite, do not trust patch-id
tools to say what is merged. Count commits against the old main from the reflog,
match subjects against the new main, then reset the branch to the new main.

## Moved from CLAUDE.md

<!-- moved from CLAUDE.md B153-a15c..B166-248b -->
## Learnings

Durable lessons mined from project history — full context and sources in
`LEARNINGS.md` (generated/maintained by the `mine-learnings` skill).

- Scripts whose output is committed/diffed across machines (like `catalog.sh`)
  must pin locale (`LC_ALL=C`) and compute counts from a controlled pre-pass,
  not a raw `find`/`wc` sweep — see LEARNINGS.md ("Cross-machine scripts must
  pin locale...").
- Skills that write files from multiple machines (like `handoff`) must scope
  filenames by hostname and verify target directory names rather than assume
  them — see LEARNINGS.md ("Handoff output paths...").
- Library-tier submodules churn independently and can inflate curated counts;
  keep headline skill totals derived only from wired/root-owned skills, and
  don't casually `--remote` update noisy library repos — see LEARNINGS.md
  ("Library submodules can churn...").
- When writing role/`SKILL.md` instructions for a rule that must never be
  violated (e.g. gh-triage skip logic), state it as an explicit imperative
  block — don't rely on step ordering to imply it — see LEARNINGS.md ("Agent
  instructions that must never be skipped...").
- Don't write bash-style unquoted-`$var` word-splitting in ad-hoc shell
  commands — Gareth's machines may run zsh, which doesn't word-split by
  default — see LEARNINGS.md ("zsh doesn't word-split...").
- A cron-driven, non-delegating role (e.g. `gh-triage`) doesn't need a project
  of its **own** — but a shared `core` project for cross-desk infra (roles no
  single desk owns, meant to survive that desk being subtracted on a
  task-specific machine) is a real category, not project-proliferation for
  its own sake. `gh-triage`, `librarian`, `researcher`, `platform-engineer`, `context-engineer` and `tron` all live there now.
- A role only looks team-owned until you ask what happens when that team is
  gated off. `researcher`'s method was always domain-agnostic — only its
  membership in `grid.yaml` made it look like a dev-team role. Moving it to
  `core` cost one `delegates_to` edit and a routing note in the orphaned
  orchestrator; the role content didn't change at all.
- Splitting a desk (e.g. `finance-desk`) out of a larger composed project is
  free when that desk's orchestrator was already standalone (not in anyone's
  `delegates_to`) — the delegation topology doesn't change, only which
  compose config file it's read from.
- A composed role's own bundled `SKILL.md` ("its operating procedure") can
  share a bare name with an unrelated wired ecosystem skill (e.g. the
  `security-reviewer` role's procedure vs. jeffallan's wired `security-reviewer`
  skill) — that's a naming coincidence, not a relationship, and reads as one
  in prose ("lives in its `security-reviewer` skill") unless a role's AGENTS.md
  says explicitly which one it means. Check for this collision whenever a role
  name and a wired skill name match.
- Before pointing a role at a wired skill for some capability, check whether
  another wired skill already covers the same ground — `jeffallan/debugging-wizard`
  and `superpowers/systematic-debugging` both do hypothesis-driven root-cause
  debugging, but they're not duplicates: `debugging-wizard` explicitly credits
  and incorporates `systematic-debugging`'s phase methodology as one of its own
  reference docs, adding stack-trace/log-correlation tooling and per-language
  debugger commands on top, while `systematic-debugging` is already the
  universal default everywhere via `superpowers`' `using-superpowers` skill —
  so neither needs a role-specific routing note on its own.
- Claude Desktop's two surfaces wire differently: the Code tab reads the wired
  `~/.claude`; Cowork reads only plugins installed in Cowork and runs subagents in a
  cloud container with staged copies (write-back replaces originals) — see
  LEARNINGS.md ("Claude Desktop surfaces differ...") and `INSTALL.md`.
- After an upstream history rewrite, `git cherry`/patch-id reports false unmerged
  commits; count `git rev-list <old-main>..<branch>` from the reflog, match subjects
  against the new main, then `git reset --hard origin/main` — see LEARNINGS.md
  ("Reconciling local branches after an upstream history rewrite").
