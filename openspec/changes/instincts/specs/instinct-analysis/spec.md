## Purpose

Turn a week of local observations into confidence-scored instincts with one cheap model call per project, under hard cost caps, and make a silent zero-output failure visible.

## ADDED Requirements

### Requirement: Analysis is weekly, batched and idempotent
The system SHALL analyse each eligible project at most once per ISO week, with at most one model call per project, and MUST skip a project already analysed that week unless forced.

#### Scenario: Double fire
- **WHEN** the weekly job runs twice in the same ISO week
- **THEN** the second run makes no model call and leaves the store byte-identical

#### Scenario: Too little data
- **WHEN** a project has fewer than 40 observations since its last analysis
- **THEN** it is skipped, no model call is made and its observations are kept

### Requirement: Analysis cost is capped
The system SHALL call the model with an explicit `--model`, no tools, a dollar cap (default 0.05), a wall-clock cap (default 120 seconds) and an input digest of at most 16000 characters, and SHALL analyse at most 5 projects per run.

#### Scenario: Invocation flags
- **WHEN** the analyser calls the model
- **THEN** the command line includes `--model haiku`, `--tools ""`, `--system-prompt`, `--setting-sources ""`, `--strict-mcp-config` and `--max-budget-usd 0.05`
- **AND** the digest is sent on stdin and the instructions only in the system prompt

#### Scenario: Call hangs
- **WHEN** the model call runs longer than the wall-clock cap
- **THEN** it is killed, the store is unchanged and the run log gets an `error` line

#### Scenario: Many projects
- **WHEN** eight projects are eligible
- **THEN** only the five with the most observations are analysed

### Requirement: The model sees a local digest and never raw secrets
The system SHALL send the model a locally built digest of scrubbed prompts, command counts, error-then-fix sequences and most-edited paths, and MUST NOT send tool output or unscrubbed text.

#### Scenario: Planted secret
- **WHEN** an observation file contains a token-shaped string
- **THEN** the stdin sent to the model and the stored instincts do not contain it

### Requirement: Confidence is computed by rule, not by the model
The system SHALL assign confidence by rule: 0.3 when new, plus 0.15 per later distinct week capped at 0.9, a decay after four missed runs, and retirement on contradiction or below 0.3.

#### Scenario: Growth over weeks
- **WHEN** the same instinct is confirmed in three consecutive weekly runs
- **THEN** its confidence is 0.3, then 0.45, then 0.6

#### Scenario: Contradiction
- **WHEN** the model returns kind `contradict` for an existing instinct
- **THEN** its status becomes `retired`

### Requirement: Malformed model output changes nothing, and an empty answer is not a failure
The system SHALL accept model output only as a JSON array (one surrounding code fence tolerated) and MUST leave the store unchanged and record an `error` outcome otherwise, and SHALL treat `[]` as a successful run that found no habit.

#### Scenario: Prose instead of JSON
- **WHEN** the model returns free text
- **THEN** no instinct file changes and the run log gets an `error` line

#### Scenario: Empty array
- **WHEN** the model returns `[]`
- **THEN** the run is recorded as `ok` with zero items returned and no error

#### Scenario: Too many items
- **WHEN** the model returns ten valid-looking items
- **THEN** the first eight are considered and the other two are counted as dropped, not treated as an error

### Requirement: The analysis prompt is a versioned file
The system SHALL load the analysis instructions from a versioned file under `scripts/instincts/prompts/`, whose header states inputs, output schema, invariants and what the model cannot see, and SHALL record the prompt version and a hash of its body in every run-record line.

#### Scenario: Version recorded
- **WHEN** a project is analysed
- **THEN** the run-record note contains `pv=1:` followed by 8 hex characters

#### Scenario: Header contract
- **WHEN** the prompt file is read
- **THEN** its front matter has `prompt`, `version`, `supersedes`, `inputs`, `output_schema`, `invariants`, `model_cannot_see` and `change`

### Requirement: The program counts and the model names
The system SHALL compute occurrence and session counts for every digest item itself and SHALL require each model item to cite digest items by reference id, rejecting any item whose citations do not support it.

#### Scenario: New instinct from one session
- **WHEN** the model returns a `new` item whose cited items all come from a single session
- **THEN** the item is dropped with reason `thin-evidence` and the store is unchanged

#### Scenario: Invented reference
- **WHEN** the model cites a reference id that is not in the digest
- **THEN** the item is dropped with reason `bad-ref`

#### Scenario: Confirm cannot rewrite
- **WHEN** the model confirms an existing instinct with different trigger or action text
- **THEN** the stored trigger and action are unchanged

#### Scenario: Contradiction needs a correction
- **WHEN** the model returns `contradict` citing no prompt marked as a correction
- **THEN** the item is dropped with reason `no-correction` and the instinct stays active

### Requirement: Captured text is treated as hostile
The system SHALL treat prompts and commands in the digest as data: the digest SHALL be delimited so item text cannot forge a delimiter or a reference line, the model call SHALL run without tools, hooks, MCP servers or skills, and any item whose trigger or action matches the unsafe-text list SHALL be dropped.

#### Scenario: Delimiter forgery
- **WHEN** a captured prompt contains the closing delimiter and a fake instinct line
- **THEN** the digest sent to the model contains neither the delimiter nor a line break from that prompt

#### Scenario: Injected command
- **WHEN** the model returns an item whose action tells the reader to fetch and run a script
- **THEN** the item is dropped with reason `unsafe-text` and never written

#### Scenario: Gate evasion
- **WHEN** the model returns an item whose action says to commit with `--no-verify`, skip the tests, or force-push
- **THEN** the item is dropped with reason `unsafe-text` and never written

### Requirement: Drops are counted so a zero is explainable
The system SHALL record for each run the number of items returned, valid and kept, and the drop count per reason, and `status` SHALL show them.

#### Scenario: Everything dropped
- **WHEN** the model returns three items and all fail validation
- **THEN** the run-record note shows `ret=3 valid=0 kept=0` and the drop reasons

#### Scenario: Repeated silent drop
- **WHEN** two consecutive runs have items returned but none kept
- **THEN** `status` prints a WARN for the project

### Requirement: Prompt quality is measured on labelled cases
The system SHALL ship labelled cases covering a repeated correction, a quiet week, a single-session claim, injected text in one and in several sessions, delimiter forgery and prompt-example leakage, SHALL check in the gate without a model call that canned good and bad replies are kept and dropped as labelled, and SHALL offer an opt-in capped live run.

#### Scenario: Gate half
- **WHEN** `instincts.sh eval-prompt --validate` runs
- **THEN** every case's canned good reply is kept, every canned bad reply is dropped with its labelled reason, and no model is called

#### Scenario: Live half needs consent
- **WHEN** `instincts.sh eval-prompt` runs without `GRID_EVALS=1` and `--yes`
- **THEN** it exits non-zero and makes no model call

### Requirement: Every run is recorded and the funnel is visible
The system SHALL write one `scripts/run-record.sh` line per analysed or skipped project with role `instincts`, and `status` SHALL warn when observations accumulate without instincts.

#### Scenario: Run log
- **WHEN** a project is analysed
- **THEN** the run log gains a line with role `instincts`, the project id as target, the outcome and the cost

#### Scenario: Silent failure surfaced
- **WHEN** a project has 250 observations since its last successful analysis
- **THEN** `status` prints a WARN for that project
