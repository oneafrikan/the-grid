## Purpose

A generic loop that improves one editable artifact against fixed fixtures using
one scalar score, keeping only improvements. Use cases: tuning a prompt against
an LLM-judge rubric, or tuning a config or script against a command's numeric
output (benchmark time, test pass count). Harness-neutral: every model call is a
user-supplied CLI command line.

## ADDED Requirements

### Requirement: Keep-or-discard improvement loop with protected ground truth
`karpathy_loop.py run <dir> [--max-iter N]` SHALL exit 2 without changes when `results.tsv` already exists; SHALL score the unmodified artifact as iteration 0 (a `keep` row described `baseline`), snapshot it into `best/` and record SHA-256 hashes of the fixtures, `program.md` and `loop.ini`; per iteration SHALL stop with exit 3 naming the file if any hash differs, run `edit_cmd` then `score_cmd`, parse the last stdout line of `score_cmd` as the score, keep only a strictly better score in the configured direction and otherwise restore from `best/`; SHALL record a non-zero exit, timeout or unparsable score as a `crash` row with an empty score, restore from `best/` and continue, stopping with exit 1 after three consecutive crashes; SHALL stop after `max_iter` iterations or `plateau_patience` consecutive iterations that did not improve best by at least `plateau_delta`; SHALL write only inside `<dir>` and print, never run, the promotion `cp` command. Every `claude -p` line in the pattern README SHALL carry `--model` and `--max-budget-usd`, and the shipped example SHALL make no model call.

#### Scenario: Baseline and refusal
- **WHEN** `run` starts on a fresh copy of `example/`
- **THEN** `results.tsv` has a header and a first row with iteration `0`, status `keep`, description `baseline`
- **AND** a second `run` on the same directory exits 2 and leaves `results.tsv` unchanged

#### Scenario: Keep, discard and direction
- **WHEN** with `direction = max` the score moves from 5 to 7, then from 7 to 6
- **THEN** the rows are `keep` then `discard`, and the working artifact equals `best/`
- **AND** with `direction = min` a move from 12 to 9 is `keep`

#### Scenario: Last line is the score
- **WHEN** `score_cmd` prints `3` then `42.5`
- **THEN** the iteration score is 42.5

#### Scenario: Crashes contained
- **WHEN** `score_cmd` exits 1 once and then succeeds, or `edit_cmd` sleeps past `cmd_timeout`
- **THEN** a `crash` row (with a timeout description for the sleep) is written and the loop continues
- **AND** three consecutive failures stop the run with exit 1

#### Scenario: Max iterations and plateau
- **WHEN** every iteration improves by 1 and `max_iter = 3`
- **THEN** exactly three iterations run after the baseline
- **AND** with `plateau_delta = 0.3`, `plateau_patience = 2` and two consecutive improvements of 0.1 the run stops before `max_iter`

#### Scenario: Agent edits a fixture
- **WHEN** the edit command modifies a file under `fixtures/`
- **THEN** the next iteration does not start and the run exits 3 naming the changed file

#### Scenario: Promotion printed, example offline, README capped
- **WHEN** `run` executes on a copy of `example/` with no network
- **THEN** it exits 0 with a best score better than the baseline, prints a `cp` command from `best/`, and modifies nothing outside the instance directory
- **AND** every README line containing `claude -p` contains `--model` and `--max-budget-usd`
