## Purpose

Let someone adopt a single role as a plain-text persona for a chat-UI Project with nothing more than a git clone.

## ADDED Requirements

### Requirement: Committed single-file personas

The repository SHALL contain `dist/personas/<role>.md` for every role in the public compose configs. Each file is generated deterministically from the role's lean body, with no frontmatter and no machine or operator values. The commit gate MUST fail when the committed files are stale.

#### Scenario: Persona is plain Markdown
- **WHEN** `dist/personas/paid-search.md` is opened
- **THEN** it starts with a `# ` title and has no YAML frontmatter, tool fields or permission fields

#### Scenario: Private roles never reach the export
- **WHEN** personas are built with a private roles directory present on the machine
- **THEN** no private role appears in `dist/personas/`

#### Scenario: Stale persona fails the gate
- **WHEN** a role's source file is edited and `dist/personas` is not rebuilt
- **THEN** `build-personas.sh --check` exits 1

#### Scenario: Rebuild is idempotent
- **WHEN** `build-personas.sh` runs twice
- **THEN** the second run changes no file
