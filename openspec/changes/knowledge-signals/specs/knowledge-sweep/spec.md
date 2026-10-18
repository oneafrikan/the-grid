## Purpose

Define how pending signals become knowledge entries, or GitHub issues and PRs for a human, using the existing `gh-triage` role and its cron pattern, with no new role and no promoter job.

## ADDED Requirements

### Requirement: The sweep is a procedure of the existing gh-triage role
The `gh-triage` role SHALL gain a knowledge-sweep step in its `SKILL.md` and matching lines in its `AGENTS.md` scope and hard rules. The sweep SHALL run in the same cron invocation as the issue pass, after it, for each repo listed under `## Knowledge sweep` in the deployment scope file, and for no other repo. No new role, skill or cron job SHALL be added. The cron schedule remains a property of the machine.

#### Scenario: Repo not listed
- **WHEN** a repo has signals but is not in the scope file's knowledge-sweep table
- **THEN** the sweep does nothing for it

#### Scenario: Scope file without the section
- **WHEN** the scope file has no `## Knowledge sweep` section
- **THEN** the run behaves exactly as before and records no knowledge-sweep line

### Requirement: Single writer in a dedicated checkout
The sweep SHALL be the only writer of `knowledge/`, `signals/done/` and `signals/done/ledger.jsonl`. It SHALL work in the checkout named in the scope file, refuse a dirty checkout, run `git pull --ff-only` first, and hold an exclusive advisory lock on `<checkout>/.git/knowledge-sweep.lock` for the run. A second concurrent run SHALL exit without writing.

#### Scenario: Concurrent runs
- **WHEN** a run starts while another holds the lock
- **THEN** it exits with outcome `skipped`, note `locked`, and writes nothing

#### Scenario: Crash
- **WHEN** a run is killed
- **THEN** the next run acquires the lock (the OS released it) and no manual cleanup is needed

#### Scenario: Dirty checkout
- **WHEN** the checkout has uncommitted changes
- **THEN** the run stops with outcome `stopped` and touches nothing

### Requirement: Four routing outcomes
For each pending signal that is valid and not a repeat, the sweep SHALL choose exactly one of: (1) no warrant: the signal is handled as `wip` and written as an unwarranted `wip` entry that can never raise a stage; (2) a `wip` or `provisional` claim, or any claim the evidence ceiling reduces to those, with no conflict: written into `knowledge/` automatically; (3) a claim of `established`: written at its ceiling, and moved to `established` only when a confirming signal from a different `filed_by`, with its own warrant, is on the entry; (4) a canon proposal, contradiction, supersession or guardrail conflict: a GitHub issue and a PR for a human, with nothing written to the sweep branch's `knowledge/`.

#### Scenario: Unwarranted claim
- **WHEN** a signal says `stage: established`, `warrant: none`
- **THEN** a `wip` entry with `unwarranted: yes` is written and the ledger disposition is `wip`

#### Scenario: Plain provisional
- **WHEN** a signal says `stage: provisional` with a warrant and no entry, conflict or citation exists
- **THEN** an entry appears in `knowledge/provisional/` with one evidence line and the signal moves to `signals/done/`

#### Scenario: Established, first filer
- **WHEN** a signal claims `established` with a warrant and no other filer has confirmed
- **THEN** the entry is written in `knowledge/provisional/` and stays there

#### Scenario: Established, confirmed by a different filer
- **WHEN** a later signal with `confirms: K-<id>` from a different `filed_by` has a warrant not identical to the first
- **THEN** the entry moves to `knowledge/established/` and the ledger disposition is `confirmed`

#### Scenario: Established, confirmed by the same filer
- **WHEN** the later signal has the same `filed_by`
- **THEN** the entry stays `provisional` and the signal's disposition is `duplicate`

#### Scenario: Canon proposal
- **WHEN** a signal claims `canonical`
- **THEN** an issue and a PR are opened and `knowledge/canon/` on the sweep branch is unchanged

#### Scenario: Supersession
- **WHEN** a signal has `supersedes: K-old`
- **THEN** an issue and a PR are opened and nothing in `knowledge/` changes on the sweep branch

#### Scenario: Declared contradiction
- **WHEN** a signal has `contradicts: K-x`
- **THEN** an issue and a PR are opened

#### Scenario: Guardrail conflict
- **WHEN** a signal cites `GUARDRAILS#G3` and the model verdict on the guardrail text is `conflict` or `unsure`
- **THEN** it is escalated; a verdict `no` lets it continue to the other rules

#### Scenario: Canon contradiction check
- **WHEN** canon is non-empty and the model verdict against the canon one-liners is an entry id or `unsure`
- **THEN** the signal is escalated

### Requirement: Processing is recorded without editing the signal
The sweep SHALL `git mv` each processed signal to `signals/done/` unchanged and append one `disposition` line to `signals/done/ledger.jsonl` with the signal filename, the claim hash (16 hex of the SHA-256 of the whitespace-collapsed, NFKC, case-folded claim), the disposition (`wip`, `written`, `confirmed`, `escalated`, `invalid`, `duplicate`, `repeat-rejected`, `secret`), the entry id, the issue and PR numbers, and the run time. A signal is processed iff its name is in the ledger or in `signals/done/`.

#### Scenario: Hash is normalised
- **WHEN** two claims differ only in case and spacing
- **THEN** they have the same claim hash

#### Scenario: Ledger is append-only
- **WHEN** a run completes
- **THEN** the previous bytes of `ledger.jsonl` are an unchanged prefix of the new file

### Requirement: Rejection memory by claim hash
A signal whose claim hash has a `rejected` resolution, with no later `reopen`, SHALL be moved to `signals/done/` with disposition `repeat-rejected` and SHALL NOT produce an entry, issue or PR. A human closing the escalation PR without merging, or labelling the issue `wontfix`, SHALL count as `rejected`; merging the PR SHALL count as `accepted`. Each run SHALL first reconcile `escalated` lines that have no `resolution` by reading PR state through `gh`, and append the `resolution`.

#### Scenario: Rejected then re-filed
- **WHEN** a human closes the PR unmerged and a new signal has the same normalised claim
- **THEN** after the next sweep the new signal is in `signals/done/` with disposition `repeat-rejected` and no new issue exists

#### Scenario: Reopen
- **WHEN** a human appends a `reopen` line for that claim hash
- **THEN** a later signal with that claim is processed normally

#### Scenario: Same claim while an escalation is open
- **WHEN** a new signal repeats a claim whose escalation has no resolution
- **THEN** its disposition is `duplicate` referencing the open issue, and no second issue is created

### Requirement: Human-review cases open an issue and a PR the sweep never merges
For each escalation the sweep SHALL create a GitHub issue labelled `knowledge` and `ready-for-human` and `severity:low` (`severity:medium` for contradiction, guardrail conflict and `secret`), with no `bug` or `enhancement` label, whose body holds the claim, warrant, filer, claimed stage, the reason, the signal path and the marker `<!-- knowledge-signal: <claim_hash> -->`. Except for `secret`, it SHALL also push a branch `knowledge/<K-id>` containing only the proposed `knowledge/` change and open a PR that references the issue. Before creating, it SHALL search issues (open and closed) for the marker and reuse a match. It SHALL NOT merge a PR, enable auto-merge, close an issue or PR, or edit `PURPOSE.md`, `GUARDRAILS.md`, `BEHAVIOUR.md` or `MAP.md`.

#### Scenario: Labels
- **WHEN** an escalation issue is created
- **THEN** it carries `knowledge`, `ready-for-human` and a severity label, and no `ready-for-agent`

#### Scenario: Crash between issue and commit
- **WHEN** a run created the issue but died before committing the ledger line
- **THEN** the next run finds the issue by marker, creates no second one, and records its number

#### Scenario: Missing label
- **WHEN** the repo has no `knowledge` label
- **THEN** the sweep creates it before the first issue

#### Scenario: Merge attempt
- **WHEN** the run's commands are inspected
- **THEN** none is `gh pr merge` or `gh pr merge --auto`

#### Scenario: The fix loop
- **WHEN** the issue loop selects issues
- **THEN** a `knowledge` issue is never selected (it is `ready-for-human`, never `ready-for-agent`)

### Requirement: Secrets and invalid signals are handled without leaking
A pending signal that fails parsing or the strict secret scan SHALL NOT be copied into `knowledge/` or shown to a model. A parse failure SHALL give disposition `invalid` (moved to `signals/done/`, no issue). A secret hit SHALL give disposition `secret`, an issue (no PR) naming the file and pattern name but not the value, and a request to rotate and scrub history.

#### Scenario: Token-shaped value
- **WHEN** a pending signal contains a token-shaped string
- **THEN** disposition is `secret`, an issue exists, and no output of the run contains the value

### Requirement: Per-run cap
The sweep SHALL process at most `Cap` pending signals per repo per run (default 10, oldest filename first), open at most 3 escalations per run, and count each PR-state reconciliation against the cap. Signals over a cap SHALL remain in `signals/` untouched.

#### Scenario: Backlog
- **WHEN** 25 valid pending signals exist and `Cap` is 10
- **THEN** exactly 10 are processed, 15 remain pending, and the run record shows `deferred=15`

#### Scenario: Escalation burst
- **WHEN** 5 pending signals all need escalation
- **THEN** 3 are escalated and the other 2 remain pending

### Requirement: Idempotent
A run with no pending signals and no unresolved escalations SHALL make no commit, no push, no `gh` write and no model call. A second run immediately after a completed run SHALL be a no-op.

#### Scenario: Rerun
- **WHEN** the sweep runs twice with no new signals between
- **THEN** the second run's `git status`, `git log` and the ledger are unchanged and `gh` was called read-only

#### Scenario: Empty queue
- **WHEN** nothing is pending
- **THEN** the run records outcome `skipped`, makes no model call and uses no judgement tokens

### Requirement: Safe target first, one commit, no partial state
The first knowledge-sweep run for a repo (no earlier `knowledge-sweep` run-record line for that target) SHALL run `knowledge.py plan` only, write nothing, and record the planned counts with outcome `skipped`. A writing run SHALL make one commit and one push of all automatic changes; if the push is rejected it SHALL rebase once and retry once, and if that fails SHALL reset the checkout to the remote branch, write nothing, and record outcome `error` with the command output pasted.

#### Scenario: First run
- **WHEN** no earlier line exists for the repo
- **THEN** no file, branch, issue or label is created, and the run record note lists the planned dispositions

#### Scenario: Protected branch
- **WHEN** the push is rejected twice
- **THEN** the checkout equals `origin/<branch>`, nothing was written, and the outcome is `error`

### Requirement: Run record and report
Each run for a repo SHALL write one `scripts/run-record.sh --role gh-triage --action knowledge-sweep --target <owner/repo>` line with outcome and a note of counts (`pending`, `processed`, `wip`, `written`, `confirmed`, `escalated`, `invalid`, `secret`, `deferred`), or state in its report that it could not. Applied changes SHALL be reported only after the git or `gh` command returned success.

#### Scenario: Counts in the note
- **WHEN** a run processes 4 signals
- **THEN** the note's counts sum to 4

### Requirement: Mechanical rules live in the helper
`scripts/knowledge.py` SHALL implement hashing, parsing and validation, the stage ceiling, ledger reads and appends, idempotency and caps, with `plan` read-only. The model SHALL decide only the guardrail-conflict and canon-contradiction judgements and write the issue and PR text. The helper SHALL have no subcommand that raises a stage by any rule other than the evidence ceiling and no command that writes `knowledge/canon/` on the sweep branch.

#### Scenario: Plan is read-only
- **WHEN** `knowledge.py plan` runs on a checkout
- **THEN** `git status --porcelain` is empty afterwards

#### Scenario: No canon write
- **WHEN** `apply` is given a plan entry for a canonical claim without `--proposal-for`
- **THEN** it exits 2 and writes nothing
