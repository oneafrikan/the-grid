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
The system SHALL call the model with no tools, a single turn, a dollar cap (default 0.05), and an input digest of at most 16000 characters, and SHALL analyse at most 5 projects per run.

#### Scenario: Invocation flags
- **WHEN** the analyser calls the model
- **THEN** the command line includes `--model haiku`, `--tools ""`, `--max-turns 1` and `--max-budget-usd 0.05`

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

### Requirement: Malformed model output changes nothing
The system SHALL accept model output only as a JSON array of at most 8 items and MUST leave the store unchanged and record an `error` outcome otherwise.

#### Scenario: Prose instead of JSON
- **WHEN** the model returns free text
- **THEN** no instinct file changes and the run log gets an `error` line

### Requirement: Every run is recorded and the funnel is visible
The system SHALL write one `scripts/run-record.sh` line per analysed or skipped project with role `instincts`, and `status` SHALL warn when observations accumulate without instincts.

#### Scenario: Run log
- **WHEN** a project is analysed
- **THEN** the run log gains a line with role `instincts`, the project id as target, the outcome and the cost

#### Scenario: Silent failure surfaced
- **WHEN** a project has 250 observations since its last successful analysis
- **THEN** `status` prints a WARN for that project
