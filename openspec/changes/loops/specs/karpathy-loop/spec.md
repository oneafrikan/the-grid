## Purpose

A generic loop that improves one editable artifact against fixed fixtures using
one scalar metric, keeping only improvements. Use cases: tuning a prompt against
an LLM-judge rubric, or tuning a config or script against a command's numeric
output (benchmark time, test pass count). Harness-neutral: every model call is a
user-supplied CLI command.

## ADDED Requirements

### Requirement: Scaffold an instance
`karpathy_loop.py init <dir>` SHALL create `loop.ini`, `program.md`, `rubric.md`, `artifact.md`, an empty `fixtures/` and a `.gitignore` ignoring `results.tsv`, `runs/` and `.guard.json`, and SHALL refuse to overwrite existing files.

#### Scenario: Fresh scaffold
- **WHEN** `init` runs on an empty directory
- **THEN** the listed files exist and `loop.ini` parses with `configparser`

#### Scenario: Existing files are kept
- **WHEN** `init` runs on a directory that already has a `loop.ini`
- **THEN** the existing file is unchanged and the command reports it skipped it

### Requirement: Baseline before edits
`run` SHALL score the unmodified artifact as iteration 0, append a `keep` row described `baseline` to `results.tsv`, and snapshot the artifact into `best/` before invoking the edit command.

#### Scenario: Baseline row
- **WHEN** `run` starts on a new instance with a command metric
- **THEN** `results.tsv` has a header and a first row with iteration `0`, status `keep`, description `baseline`

### Requirement: Keep or discard on a scalar
After each edit the loop SHALL keep the artifact only when the new score is strictly better than the best score in the configured direction, and otherwise SHALL restore the artifact from `best/`.

#### Scenario: Improvement kept
- **WHEN** the score moves from 5 to 7 with `direction = max`
- **THEN** the row status is `keep` and `best/` holds the new artifact

#### Scenario: Regression discarded
- **WHEN** the score moves from 7 to 6 with `direction = max`
- **THEN** the row status is `discard` and the working artifact equals `best/`

#### Scenario: Minimise direction
- **WHEN** `direction = min` and the score moves from 12 to 9
- **THEN** the row status is `keep`

### Requirement: Two metric kinds
The loop SHALL support a `command` metric, whose score is the last stdout line of `score_cmd` parsed as a number, and a `judge` metric, whose score is the last `SCORE: <number>` line of `judge_cmd` run on the rubric plus the output of the optional `run_cmd` (or the artifact when absent).

#### Scenario: Command metric
- **WHEN** `score_cmd` prints `3` then `42.5`
- **THEN** the iteration score is 42.5

#### Scenario: Judge metric
- **WHEN** `judge_cmd` prints text ending with `SCORE: 8.5`
- **THEN** the iteration score is 8.5
- **AND** the raw judge text is saved under `runs/<iteration>/judge.txt`

#### Scenario: Out-of-range judge score
- **WHEN** the judge prints `SCORE: 14` with `scale_max = 10`
- **THEN** the iteration is a `crash` and the artifact is restored from `best/`

### Requirement: Crashes are contained
A failed command, timeout, unparsable score or out-of-range score SHALL record a `crash` row with an empty score, restore the artifact from `best/`, and continue; three consecutive crashes SHALL stop the run.

#### Scenario: Single crash continues
- **WHEN** `score_cmd` exits 1 once and then succeeds
- **THEN** one `crash` row exists and the loop continues

#### Scenario: Three crashes stop
- **WHEN** `score_cmd` fails on three consecutive iterations
- **THEN** the run stops with a non-zero exit

### Requirement: Stop on plateau or max iterations
The loop SHALL stop after `max_iter` iterations, or after `plateau_patience` consecutive iterations that did not improve the best score by at least `plateau_delta`.

#### Scenario: Max iterations
- **WHEN** every iteration improves by 1 and `max_iter = 3`
- **THEN** exactly three iterations run after the baseline

#### Scenario: Plateau
- **WHEN** `plateau_delta = 0.3`, `plateau_patience = 2` and two consecutive iterations improve by 0.1 or less
- **THEN** the run stops before `max_iter`

### Requirement: Ground truth is protected
The loop SHALL record SHA-256 hashes of the fixtures, rubric, `program.md` and `loop.ini` at baseline and SHALL stop with exit code 3 when any differs before an iteration begins.

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

### Requirement: Re-running resumes
Running again on an instance with an existing `results.tsv` SHALL continue iteration numbering from the last row, take the best score from the kept rows, and not repeat the baseline.

#### Scenario: Resume
- **WHEN** `run --max-iter 2` is invoked twice
- **THEN** the second invocation's first row has iteration number 3 and no second baseline row exists

### Requirement: Commands are bounded
Every user command SHALL run with `cmd_timeout` seconds and the working directory set to the instance directory.

#### Scenario: Hanging command
- **WHEN** `edit_cmd` sleeps longer than `cmd_timeout`
- **THEN** the iteration is recorded as `crash` with a timeout description
