## Purpose

Let someone adopt a single role as a plain-text persona for a chat UI Project with nothing more than a git clone.

## ADDED Requirements

### Requirement: Committed single-file personas

The repository SHALL contain `dist/personas/<role>.md` for every role in the public compose configs, generated deterministically from role sources with no frontmatter and no personal data, and the commit gate MUST fail when the committed files are stale.

#### Scenario: Persona is plain Markdown
- **WHEN** `dist/personas/paid-search.md` is opened
- **THEN** it starts with a `# ` title, has no YAML frontmatter and no tool or permission fields

#### Scenario: No personal data
- **WHEN** personas are built on a machine with a populated `agent-factory/user.yaml` and private roles directory
- **THEN** the output contains none of its values, the hostname, or any private role

#### Scenario: Stale persona fails the gate
- **WHEN** a role's `SOUL.md` is edited and `dist/personas` is not rebuilt
- **THEN** `build-personas.sh --check` exits 1

#### Scenario: Rebuild is idempotent
- **WHEN** `build-personas.sh` runs twice
- **THEN** the second run changes no file
