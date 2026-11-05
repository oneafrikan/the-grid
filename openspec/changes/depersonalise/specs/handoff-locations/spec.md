## Purpose

Let the handoff skill ship with one neutral, fixed save location, with no personal folder rules in the public tree.

> **Amended 2026-11-05 (commit e6b0a44).** This capability originally let a private table (`~/.the-grid-private/handoff-locations.md`) override the save location per project, with `LOGS/` as the default asked about before creating. That table is no longer read, by the skill or by the auto-handoff worker. The capability name is kept so the history stays traceable.

## ADDED Requirements

### Requirement: Save location resolution

The handoff skill SHALL save both files to the `LOGS` folder of the project the session ran in, and nowhere else. The project is the git repo root containing the working directory, else the working directory itself. An existing `logs`, `Logs` or `LOGS` directory there SHALL be used as it is (no second directory in another casing); when none exists the skill SHALL create `LOGS` without asking. No per-project table, environment variable or repo ownership changes the location.

#### Scenario: No private table

- **WHEN** `~/.the-grid-private/handoff-locations.md` does not exist
- **THEN** the skill writes to `<project>/LOGS`, creating it if absent

#### Scenario: A private table is ignored

- **WHEN** the private table has a row for the current project directory
- **THEN** the skill still saves to `<project>/LOGS`

#### Scenario: Existing folder in another casing

- **WHEN** the project already has a `Logs` directory
- **THEN** the skill writes there and creates no `LOGS`

#### Scenario: Skill text carries no personal examples

- **WHEN** `scripts/check-personal.sh` is run on the `skills/handoff/` files
- **THEN** it reports no finding
