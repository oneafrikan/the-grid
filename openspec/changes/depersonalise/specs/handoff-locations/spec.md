## Purpose

Let the handoff skill ship with a neutral default save location while allowing each user to keep personal per-project folder rules in their private repo.

## ADDED Requirements

### Requirement: Save location resolution

The handoff skill SHALL use the first row of `~/.the-grid-private/handoff-locations.md` whose first column matches the current working directory name or path glob, and SHALL otherwise save to `LOGS/` in the current project, asking before creating it.

#### Scenario: No private table

- **WHEN** `~/.the-grid-private/handoff-locations.md` does not exist
- **THEN** the skill writes to `LOGS/`, asking before creating the directory if absent

#### Scenario: Private row matches

- **WHEN** the private table has a row for the current project directory
- **THEN** the skill saves to that row's location instead of `LOGS/`

#### Scenario: Private row does not match

- **WHEN** the private table exists but no row matches
- **THEN** the skill falls back to `LOGS/`

#### Scenario: Skill text carries no personal examples

- **WHEN** `scripts/check-personal.sh` is run on the `skills/handoff/` files
- **THEN** it reports no finding
