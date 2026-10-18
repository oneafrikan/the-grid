## Why

Agents learn things (a command that works, a trap, a decision) and today nothing durable carries them between sessions, machines or agents except hand-edited `LEARNINGS.md` and the private instincts store. `charter-files` (A1) gives every project a shared map and a stage vocabulary; it does not say how a claim gets from an agent's head into the repo, how much trust it has earned, or who may raise it. The only existing hand-off mechanism is `signals/→<agent>.md` appends (AGENTS_base "Signal Protocol"): free text, one file per recipient, edited in place, never swept into anything.

This change reuses the shape the operator already runs (agents file markdown signals; `gh-triage` sweeps on cron and files GitHub issues) and applies it to knowledge. Agents file immutable signals; one sweep writes the store; anything that changes what the project treats as settled goes to a human.

## What Changes

- `signal-format`: a signal is one immutable markdown file in the project's own repo, `signals/<UTC timestamp>-<filer>-<hash6>.md`, with fixed frontmatter (`filed_by`, `claim`, `stage`, `warrant`, optional `supersedes` / `contradicts` / `confirms` / `guardrail`, `status: pending`). No secrets. Per-repo convention README seeded with the repo.
- `knowledge-sweep`: the existing `gh-triage` role (core) gains a knowledge pass. Per pending signal, one of four routing outcomes: stays `wip` (no warrant); written to `knowledge/` (wip/provisional, no conflict); `established` only after a confirming signal from a different filer with its own warrant; or a GitHub issue (`knowledge` + `ready-for-human`) plus a PR that only a human merges (canon, contradiction, supersession, guardrail conflict). Processed signals move to `signals/done/` with a claim hash in an append-only ledger so rejected claims are never re-raised. Per-run cap; a rerun is a no-op; the sweep is the only writer.
- `knowledge-store`: `knowledge/<stage>/` layout, `knowledge/canon/` for canonical only, entry format with a stable id and `K-<hash8>[#slug]` addresses, evidence list, supersede handling.
- A small stdlib helper `scripts/knowledge.py` (`hash`, `file`, `check`, `plan`, `apply`) holds the mechanical rules (parsing, hashing, ceilings, ledger, idempotency) so the cron model only makes the judgement calls. It is mirrored into `project-factory/templates/_common/scripts/` so projects carry it. No `promote` command, no promoter job.
- Edits to the `gh-triage` role files, its scope-file template and spec doc; completion of the `signals/README.md` and `knowledge/README.md` that `charter-files` seeds. The "Filing a Knowledge Signal" block in `AGENTS_base.md` is A1's to word (A1 owns it); this change supplies the field list.

## Capabilities

### New Capabilities

- `signal-format`: file naming, frontmatter, immutability, secrets rule, privacy, convention README.
- `knowledge-sweep`: the gh-triage knowledge procedure.
- `knowledge-store`: layout, entry format, addresses, supersede handling.

### Modified Capabilities

No spec delta: `openspec/specs/` does not exist yet, so there is no baseline to modify. Existing behaviour and text this change does alter, none of it specified as a capability today: the `gh-triage` role (new knowledge pass, wider outward channel), A1's seeded `signals/README.md` and `knowledge/README.md` (A1's `project-charter-files` requirement on their content, sweep status wording), and `docs/architecture.md` (new script listed).

## Impact

- New: `scripts/knowledge.py` and its mirror `project-factory/templates/_common/scripts/knowledge.py` (byte-identical, `cmp` test), `tests/test_knowledge_{core,sweep,seed,secrets}.bats`, `tests/test_gh_triage_knowledge.bats`, `evals/cases/gh-triage/knowledge-*.yaml`, `.gitkeep` in the five stage directories A1 does not seed (`wip`, `provisional`, `established`, `superseded`, `retired`), in `_common` and in the-grid.
- Edited: `agent-factory/roles/gh-triage/{AGENTS.md,SKILL.md,deployment-scope.template.md}`, `agent-factory/docs/gh-triage-spec.md`, `signals/README.md` and `knowledge/README.md` in the-grid and in `project-factory/templates/_common` (A1's files, extended), `tests/test_charter_files.bats` (A1's sweep-status assertion), `docs/architecture.md` (lists `scripts/knowledge.py`; `signals/` and `knowledge/` are A1's additions), `MAP.md` (regenerated in the commit that adds the `Knowledge sweep` heading), `CLAUDE.md` key-files list, `project-factory/templates/_common/.grid/project.yaml` (one comment recommending `hooks.profile: standard` where signals are used). Generated and checked by the gate: `dist/personas/gh-triage.md`, `plugins/grid-core/agents/core-gh-triage.md`. Not edited here: `agent-factory/_core/AGENTS_base.md` (A1 owns the "Filing a Knowledge Signal" block and writes the final wording including this change's fields).
- Depends on `charter-files` (A1), read in this worktree as an unmerged change (`openspec/changes/charter-files/`): it seeds `signals/README.md`, `knowledge/README.md` and `knowledge/canon/.gitkeep`, owns the "Filing a Knowledge Signal" block in `AGENTS_base.md` (final wording includes this change's fields), and its map reads `stage` and `claim` from entries and looks for a `Knowledge sweep` heading in `gh-triage/AGENTS.md`. A1's files are not built yet; every statement about them is from its change documents, not from code.
- `epistemic-enforcement` (A3) depends on this change: `map.py --check` imports the parser in `scripts/knowledge.py`.
- Cost: zero model calls when nothing is pending; otherwise at most one cron run's worth of judgement calls, capped at 10 signals per repo per run.
- Labels: adds `knowledge` to each swept repo. State labels reuse the existing scheme (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`; severity `critical`/`high` always `ready-for-human`).

## Business-tier fit

- A business repo `the-grid-<business>` is a project repo (docs/business-tier, PR #280; not in this worktree, taken from the brief). Its signals land in that repo and are swept there, never in the public grid.
- A colleague using Claude Desktop (Cowork) can file only if Cowork can commit and push. UNVERIFIED; the pilot answers it. Until then such a colleague has no filing route (open question 1).
- The sweep checkout and `gh` login are the operator's own; no new identity is introduced.

## Non-goals

- No weekly promoter job, confirmer agent, `knowledge.py promote`, canon-PR runner or cli-cron.
- No new role; `gh-triage` is extended.
- No change to `mine-learnings`, `LEARNINGS.md` or the `instincts` change. `LEARNINGS.md` and `knowledge/` stay separate.
- No automatic canon, supersession or retirement. Retiring an entry is a human PR, not a signal.
- No cross-repo signals: a signal is swept only in the repo that holds it. No private-tier sync.
- No separate OS user, sudo, GitHub App token or isolation between Claude Code sessions. Same user, the operator's own `gh` login and checkout.
- No semantic search or embedding of entries; no detection of undeclared contradictions beyond the canon check in `knowledge-sweep`.
- No MAP.md generation, stage lint or Stop hook (A3). No signal GUI.
- No design of the business tier.

## Open assumptions (operator can veto)

1. (Approved, operator D10.) A small stdlib helper `scripts/knowledge.py` exists for the mechanical rules. Alternative: prose-only procedure in the gh-triage SKILL, with the model hashing and moving files. Rejected as the default because idempotency and rejection memory must not depend on model care.
2. Processed signals are never edited: disposition lives in an append-only `signals/done/ledger.jsonl`, not in the signal. (The shared brief says the sweep "records disposition and a claim hash" and signals are "never edited"; both hold only with a ledger.)
3. Entries accumulate an evidence list; stage is a function of evidence (no warrant: `wip`; one warranted filer: at most `provisional`; two different warranted filers: `established`). A signal claiming a higher stage than its evidence supports is written at the ceiling.
4. A signal with no warrant is written as a `wip` entry marked unwarranted (not dropped). It can never raise an entry's stage.
5. (`<hash6>` in the file name is any six hex characters, operator D2; the helper uses the SHA-256 prefix.) Optional frontmatter field `confirms: <entry address>` is added to the brief's list so a confirmer does not have to reproduce a claim word for word.
6. Supersession and canon proposals are always human; `retired` is not claimable by a signal.
7. Automatic dispositions are committed by the sweep directly to the repo's sweep branch (default branch unless the scope file says otherwise); only escalations use a PR.
8. Defaults: 10 signals per run per repo, at most 3 issue+PR escalations per run.
9. The sweep works in a dedicated checkout named in the gh-triage scope file, never the operator's working tree.
10. Evidence vocabularies (shared-brief assumption, carried here for the veto): stage for knowledge, `RAN / READ / UNTESTED` for completion claims, a mapping table for `STATED / OBSERVED / INFERRED`, `H / M / L` and the librarian `tier`. This change stores `warrant` as free text and does not map or delete any vocabulary. The mapping table belongs to A1/A3.
11. Knowledge signals and the existing `signals/→<agent>.md` hand-off files share the `signals/` directory, told apart by filename; the sweep ignores `→*.md`. (Approved, operator D9: coexist.)
12. (Approved, operator D7.) A signal may claim any of `wip`, `provisional`, `established`, `canonical` as a proposal; the sweep caps the outcome by evidence. `canonical`, supersession and retirement are always human. A1 owns the `AGENTS_base` wording and states this.
13. Lean project agents (`deploy.py`) are told "Signal-file hand-offs (`signals/`) do not apply" (`compose.py:741`). That sentence is left alone (no `compose.py` change); the trailhead and `signals/README.md` are the route for knowledge signals.
14. Where a repo's `.grid/project.yaml` leaves `hooks.profile` at its default (`off`), the commit-time secret scan does not run; the sweep's own scan is then the only check.

## Open questions

1. Can Cowork commit and push? (pilot check; blocks colleague filing)
2. Who may file from a non-terminal environment, and under what `filed_by`?
3. Which branch does the sweep write to for the-grid itself (signals land via PRs into `next`, then `main`), and is that branch protected? UNVERIFIED; if protected, direct sweep commits fail and assumption 7 needs a PR path.
