## Purpose

Pin the epistemic rules of `researcher` and `librarian` with golden cases, so a prompt, schema or model change shows up as a pass-rate change.

## ADDED Requirements

### Requirement: Six validated cases
`evals/cases/researcher/` SHALL hold `unread-source-claimed.yaml`, `one-origin-three-articles.yaml`, `inference-labelled-as-fact.yaml`; `evals/cases/librarian/` SHALL hold `source-without-tier.yaml`, `two-sources-contradict.yaml`, `query-without-wiki.yaml`. Each SHALL pass `run_evals.py --validate`, have `finding: "#0"`, a non-empty `must_match`, and a comment header saying which role rule it pins.

#### Scenario: Validate
- **WHEN** `agent-factory/.venv/bin/python agent-factory/run_evals.py --validate` runs
- **THEN** it reports 0 problems and `--list` shows all six cases

#### Scenario: Selection
- **WHEN** `run_evals.py --changed` is given a range that touches `agent-factory/roles/librarian/SOUL.md`
- **THEN** the three librarian cases are selected and no researcher case is

### Requirement: Hint-free scenarios
A case prompt SHALL NOT name the rule under test or state what is missing; the answer SHALL be a choice among format-line options, and the passing option SHALL be listed first in at most 2 of the 6 cases.

#### Scenario: Review
- **WHEN** a reviewer reads each prompt with its `must_match` hidden
- **THEN** the correct option is not stated or implied by the scenario text

#### Scenario: Option order
- **WHEN** the six format lines are compared with their `must_match` regexes
- **THEN** the passing option is first in no more than 2 of them

### Requirement: Rules the lean render carries
Every case SHALL test a rule written in the role's own `SOUL.md`, `AGENTS.md` or `SKILL.md` (the lean render's inputs), not a rule that exists only in `_core/AGENTS_base.md`.

#### Scenario: Traceability
- **WHEN** each case header's cited rule is searched in the role's files
- **THEN** the sentence is found

### Requirement: Opt-in, capped, tool-less
The cases SHALL run only through `run_evals.py` (`GRID_EVALS=1` and `--yes`), never from `gate.sh`. Baselining SHALL print the worst-case spend first (3 runs x $0.25 x 3 cases = $2.25 per role at defaults) and stay under `--max-total`.

#### Scenario: Dry run
- **WHEN** `run_evals.py --role researcher --dry-run` runs
- **THEN** it prints a plan with 3 cases, worst-case $2.25, and calls no model

#### Scenario: Gate unchanged
- **WHEN** `gate.sh` runs
- **THEN** it calls `run_evals.py --validate` (via the existing test) and never a real run

### Requirement: Baseline recorded honestly
Each case SHALL ship `expect_today: unknown`. After the operator-approved baseline run, `expect_today` SHALL be set to `pass` or `fail` per the measured rate, and a case that FLIPS SHALL stay `unknown` with the rates in its header comment. An errored run (for example not logged in) SHALL NOT be recorded as a failure.

#### Scenario: After baseline
- **WHEN** the baseline results file shows 3/3 passes for a case
- **THEN** the case header records the date and `expect_today: pass`
