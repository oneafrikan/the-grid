## Purpose

Let the handoff skill ship with a neutral default save location while allowing each user to keep personal per-project folder rules in their private repo.

## ADDED Requirements

### Requirement: Neutral default location

The handoff skill SHALL save handoff and context files to `LOGS/` in the current project (asking before creating it) when no private table matches.

#### Scenario: No private table

- **WHEN** `~/.the-grid-private/handoff-locations.md` does not exist
- **THEN** the skill writes to `LOGS/`, asking before creating the directory if absent

### Requirement: Optional private location table

The handoff skill MUST read `~/.the-grid-private/handoff-locations.md` when it exists and SHALL use the first table row whose first column matches the current working directory name or path glob.

#### Scenario: Private row matches

- **WHEN** the private table has a row for the current project directory
- **THEN** the skill saves to that row's location instead of `LOGS/`

#### Scenario: Private row does not match

- **WHEN** the private table exists but no row matches
- **THEN** the skill falls back to `LOGS/`

### Requirement: Skill text carries no personal examples

The handoff skill and its templates MUST use neutral machine and project examples and MUST NOT name the author, real hosts, or private projects.

#### Scenario: Scan passes on skill files

- **WHEN** `scripts/check-personal.sh` is run on the `skills/handoff/` files
- **THEN** it reports no finding
