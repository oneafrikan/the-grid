## Purpose

A generic loop that improves one editable artifact against fixed fixtures using
one scalar score, keeping only improvements. Use cases: tuning a prompt against
an LLM-judge rubric, or tuning a config or script against a command's numeric
output (benchmark time, test pass count). Harness-neutral: every model call is a
user-supplied CLI command line.

## ADDED Requirements

### Requirement: Baseline before edits
`karpathy_loop.py run <dir>` SHALL score the unmodified artifact as iteration 0, append a `keep` row described `baseline` to `results.tsv`, and snapshot the artifact into `best/` before invoking the edit command, and SHALL exit 2 without changes when `results.tsv` already exists.

#### Scenario: Baseline row
- **WHEN** `run` starts on a fresh copy of `example/`
- **THEN** `results.tsv` has a header and a first row with iteration `0`, status `keep`, description `baseline`

#### Scenario: Existing results are not overwritten
- **WHEN** `run` starts on a directory that already has `results.tsv`
- **THEN** it exits 2 and `results.tsv` is unchanged

### Requirement: Keep or discard on a scalar
The loop SHALL parse the last stdout line of `score_cmd` as the score, keep the artifact only when the score is strictly better than the best in the configured direction, and otherwise restore the artifact from `best/`.

#### Scenario: Improvement kept
- **WHEN** the score moves from 5 to 7 with `direction = max`
- **THEN** the row status is `keep` and `best/` holds the new artifact

#### Scenario: Regression discarded
- **WHEN** the score moves from 7 to 6 with `direction = max`
- **THEN** the row status is `discard` and the working artifact equals `best/`

#### Scenario: Minimise direction
- **WHEN** `direction = min` and the score moves from 12 to 9
- **THEN** the row status is `keep`

#### Scenario: Last line is the score
- **WHEN** `score_cmd` prints `3` then `42.5`
- **THEN** the iteration score is 42.5

### Requirement: Crashes are contained
A non-zero exit, timeout or unparsable score SHALL record a `crash` row with an empty score, restore the artifact from `best/`, and continue; three consecutive crashes SHALL stop the run with exit 1.

#### Scenario: Single crash continues
- **WHEN** `score_cmd` exits 1 once and then succeeds
- **THEN** one `crash` row exists and the loop continues

#### Scenario: Three crashes stop
- **WHEN** `score_cmd` fails on three consecutive iterations
- **THEN** the run stops with exit 1

#### Scenario: Hanging command
- **WHEN** `edit_cmd` sleeps longer than `cmd_timeout`
- **THEN** the iteration is recorded as `crash` with a timeout description

### Requirement: Stop on plateau or max iterations
The loop SHALL stop after `max_iter` iterations (overridable by `--max-iter`), or after `plateau_patience` consecutive iterations that did not improve the best score by at least `plateau_delta`.

#### Scenario: Max iterations
- **WHEN** every iteration improves by 1 and `max_iter = 3`
- **THEN** exactly three iterations run after the baseline

#### Scenario: Plateau
- **WHEN** `plateau_delta = 0.3`, `plateau_patience = 2` and two consecutive iterations improve by 0.1 or less
- **THEN** the run stops before `max_iter`

### Requirement: Ground truth is protected
The loop SHALL record SHA-256 hashes of the fixtures, `program.md` and `loop.ini` at baseline and SHALL stop with exit code 3 when any differs before an iteration begins.

#### Scenario: Agent edits a fixture
- **WHEN** the edit command modifies a file under `fixtures/`
- **THEN** the next iteration does not start
- **AND** the run exits 3 naming the changed file

### Requirement: Nothing is promoted automatically
The loop SHALL write only inside the instance directory, and at exit SHALL print the copy command for promotion without running it.

#### Scenario: Promotion is printed
- **WHEN** a run finishes
- **THEN** the output contains a `cp` command from `best/` to a destination placeholder
- **AND** no file outside the instance directory was modified

### Requirement: Documented model commands are capped
Every model-calling command line shown in the pattern README SHALL name an explicit model and a spend cap, and the shipped example SHALL make no model call.

#### Scenario: README examples
- **WHEN** the README is searched for lines containing `claude -p`
- **THEN** each such line contains `--model` and `--max-budget-usd`

#### Scenario: Offline example
- **WHEN** `run` executes on a copy of `example/` with no network
- **THEN** it finishes with exit 0 and a best score better than the baseline
