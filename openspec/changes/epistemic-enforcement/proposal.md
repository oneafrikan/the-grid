## Why

`charter-files` (A1) and `knowledge-signals` (A2) add prose rules, a signal template and a sweep. Prose is advisory: nothing fails when a signal has a bad `stage`, a `supersedes` address points at nothing, a "canonical" entry sits outside `knowledge/canon/`, or an agent says "done" with no evidence. This change adds the mechanical checks that make those failures loud, and keeps canon changes behind a human.

## What Changes

- `scripts/map.py --check` also lints `signals/` and `knowledge/` through the shared parser in `scripts/knowledge.py` (A2): stage enum and stage-vs-directory, signal grammar and unedited-since-filing (from git history, per A2), warrant and the different-filer rule re-derived from evidence, ledger consistency, and that every frontmatter address resolves. It rides A1's existing `map` gate check; no second check is added. The project-template copy of `knowledge.py` is A2's.
- Optional Stop hook `hooks/scripts/epistemic-stop.sh` (catalogue entry, profile `strict`, fails open): when the last assistant message claims completion with no `RAN` / `READ` / `UNTESTED`, block once and ask for the warrant.
- Canon protection: `.github/CODEOWNERS` entry for `knowledge/canon/`, a PR-template checkbox, an explicit "canon PRs are never merge-on-green" block in `CLAUDE.md`, a test that the sweep's direct-commit path cannot write canon, and a HUMAN task to decide whether to harden the existing `next` ruleset.
- Golden eval cases for `researcher` and `librarian` (3 each, none exist today), run by the existing opt-in, capped, tool-less `run_evals.py`.

## Capabilities

### New Capabilities

- `map-lint`: stage, signal, warrant, canon-placement and address checks inside `map.py --check`, run by the gate.
- `completion-warrant-hook`: optional Stop hook asking for a warrant on completion claims.
- `canon-protection`: canon changes only through a human-reviewed PR; excluded from merge-on-green.
- `role-evals`: golden cases pinning the epistemic rules of `researcher` and `librarian`.

### Modified Capabilities

- `repo-map` (A1): its requirement that `map.py --check` "SHALL perform no validation beyond" the MAP.md comparison is changed: `--check` also lints `signals/` and `knowledge/`. The delta is `specs/repo-map/spec.md` (MODIFIED "Drift check"); archive after A1, and A1's text must not be built as written. `openspec/specs/` is empty on this branch; `map.py`, `knowledge.py`, `knowledge/`, `signals/` come from A1 and A2 drafts.

## Impact

- Files: `scripts/map.py`, `hooks/scripts/epistemic-stop.sh`, `hooks/catalogue.json`, `hooks/README.md`, `.github/CODEOWNERS`, `.github/pull_request_template.md`, `CLAUDE.md`, `docs/architecture.md` (one line for the new hook), `evals/cases/{researcher,librarian}/*.yaml`, `tests/test_map_lint.bats`, `tests/test_gate.bats`, `tests/test_hooks.bats`, `tests/test_epistemic_stop.bats`. `scripts/gate.sh` is not edited (A1 owns the `map` check).
- No change to `compose.py`, `deploy_hooks.py`, `run_evals.py`, `mine-learnings` or the `instincts` change.
- Depends on `knowledge-signals` (`knowledge.py` parser and resolver, ledger, `knowledge/<stage>/` layout) and through it on `charter-files` (`map.py`, its gate check and project mirror, `GUARDRAILS.md`, the RAN/READ/UNTESTED vocabulary in `AGENTS_base.md`). Both are drafts in this worktree and are being revised; re-read them at build time.
- Use case for new assets: none are new asset types. One catalogue entry and four eval-case groups; each serves the same use case, an agent claim that cannot be traced to evidence being caught before it becomes team knowledge.

## Business-tier fit

- A business repo `the-grid-<business>` is a project repo seeded with the same charter files, so it gets the same `map.py --check` and gate.
- Its `knowledge/canon/` gets the same CODEOWNERS and PR rule; the owner handle is the business operator's, not a real name in this public repo.
- The Stop hook needs a terminal Claude Code session. Colleagues on Cowork get none of L2; whether Cowork runs hooks is UNVERIFIED (pilot, cf. docs/business-tier, PR #280).
- Lint runs in the business repo's CI, not on a colleague's machine, so a non-terminal user still cannot land a malformed signal.

## Non-goals

- No promoter job, confirmer agent, `knowledge.py promote`, canon-PR runner or cli-cron.
- No new role; no `compose.py` change; no change to `deploy_hooks.py` (the hook uses the existing `min_profile` field).
- No deletion or merge of the four evidence vocabularies.
- No git-history check (A2's filename hash already detects edits from the tree).
- No lint of addresses in prose bodies.
- No second parser: the lint imports A2's.
- No change to repo rulesets by this change; that is a HUMAN task with a recommendation.
- No eval case that needs a tool, a network call or a full-profile role.
- No ruleset or branch-protection change (operator decision); no CI job in project templates, only the pre-commit gate.
- No Stop-hook trial on any project in this change.

## Open assumptions (operator can veto)

1. Evidence vocabularies (inherited from A1): stage for knowledge, RAN/READ/UNTESTED for completion claims, a mapping table for STATED/OBSERVED/INFERRED, H/M/L and librarian `tier`; none deleted.
2. The Stop hook ships in profile `strict`, which today adds nothing; no project and not the-grid itself turns it on in this change (trial deferred).
3. Lint uses git only for the unedited-since-filing check (skipped with a notice without git), never the network, and checks addresses only in frontmatter fields. Its output does not depend on MAP.md counts.
4. The brief says A3 wires `map.py --check` into the gate; A1's draft already does, so this change does not. Veto if you want it wired here instead.
5. CODEOWNERS is added as a file; no ruleset is touched. The protection against a direct canon write is the sweep-has-no-canon-write-path test.
6. New eval cases ship with `expect_today: unknown` until a baseline run the operator pays for.
7. Project repos get the lint through A2's mirror of `knowledge.py` into the template; they get only the pre-commit gate for `map.py --check`, no CI job.
8. Frontmatter handling is A2's flat grammar; this change adds none.

## Open questions

1. Can Cowork commit and push? (pilot check; unresolved)
2. Who may file a signal from a non-terminal environment? (unresolved)
