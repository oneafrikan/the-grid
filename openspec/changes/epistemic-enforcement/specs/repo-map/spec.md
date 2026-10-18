## Purpose

Delta against `charter-files` (A1) `repo-map`: `map.py --check` now also lints knowledge. Archive after A1.

## MODIFIED Requirements

### Requirement: Drift check
`python3 scripts/map.py --check` SHALL write nothing and exit 0 when `MAP.md` equals the freshly generated text and the knowledge lint (capability `map-lint`) finds nothing, 1 when `MAP.md` differs or is missing (printing `run: python3 scripts/map.py`) or the lint has findings, and 2 when it could not compare or lint. MAP.md SHALL NOT be an input to the lint, so a commit that only files or sweeps a signal leaves `--check` green.

#### Scenario: Current
- **WHEN** MAP.md was just generated and the lint is clean
- **THEN** `--check` exits 0 and modifies no file

#### Scenario: Stale
- **WHEN** a new file `CONTEXT.md` is added without regenerating
- **THEN** `--check` exits 1 and prints the regenerate command

#### Scenario: Missing
- **WHEN** MAP.md does not exist
- **THEN** `--check` exits 1

#### Scenario: Unknown flag
- **WHEN** `map.py --chek` runs
- **THEN** it exits 2 and writes no file

#### Scenario: Lint finding with current MAP.md
- **WHEN** MAP.md is current and a signal has an invalid key
- **THEN** `--check` exits 1 and prints one `E_` line

#### Scenario: Signal filed or swept
- **WHEN** a commit adds a valid signal, or moves a signal to `signals/done/` with its ledger line and writes its entry
- **THEN** `--check` exits 0 with MAP.md unchanged
