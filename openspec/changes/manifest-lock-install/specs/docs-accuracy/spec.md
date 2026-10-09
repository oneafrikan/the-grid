## Purpose

Keep public documentation truthful about which factories exist.

## ADDED Requirements

### Requirement: Docs name only factories that exist
Tracked public documentation (`README.md`, `automation-factory/README.md`, `project-factory/README.md`, `CLAUDE.md`) MUST NOT reference a `skills-factory/` directory, and the repository MUST NOT contain an empty `skills-factory/` directory.

#### Scenario: No dangling references
- **WHEN** the bats suite greps those files for `skills-factory`
- **THEN** there are no matches

#### Scenario: Directory removed
- **WHEN** the suite checks for `skills-factory/`
- **THEN** it either does not exist or contains tracked files
