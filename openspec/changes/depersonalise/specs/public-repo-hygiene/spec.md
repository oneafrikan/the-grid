## Purpose

Define what may appear in the public the-grid tree and where personal material lives instead, so a stranger who clones it inherits a framework and not someone's infrastructure.

## ADDED Requirements

### Requirement: No personal data in the public tree

The public repo MUST NOT contain machine host names, non-owner account or organisation handles, real email addresses, absolute home-directory paths, private network addresses, credentials, or the names of private projects, and MUST keep such material in the private repo.

#### Scenario: Example identity file uses placeholders

- **WHEN** a user opens `agent-factory/user.yaml.example`
- **THEN** every example value is a placeholder on `example.com` or a neutral label, and no real name, email or host name appears

#### Scenario: Deployment specifics live elsewhere

- **WHEN** a doc or template needs a table of real deployments (hosts, accounts, channels)
- **THEN** the public file states that each install keeps that table in its own infra repo and contains no row of real values

### Requirement: Archive before delete

The public repo MUST NOT track third-party archives or documents whose redistribution licence is unclear, and the move SHALL copy each removed file to the private repo and verify its hash before removing it, with a re-run being a no-op.

#### Scenario: Third-party playbook archived

- **WHEN** the move completes
- **THEN** `__assets/` and `docs/playbook-ai-dev-team.md` are absent from the public tree and the private `archive/clawguides/` hashes match the originals listed in `archive/MANIFEST.sha256`

#### Scenario: Removal blocked without archive

- **WHEN** `archive/MANIFEST.sha256` is missing or a listed hash differs from the working-tree file
- **THEN** no file is removed and the task stops with a blocked status

#### Scenario: Second run is clean

- **WHEN** the removal group is run again after success
- **THEN** it changes nothing and `git status --porcelain` is empty

### Requirement: Author voice allowed, rendered text neutral

Prose documentation MAY refer to the author by name, and text rendered into other people's agents, workspaces or skills MUST address "the operator" instead.

#### Scenario: Author named in prose

- **WHEN** `README.md` or `CLAUDE.md` says the project is the author's
- **THEN** the gate does not flag it

#### Scenario: Author named in a rendered template

- **WHEN** a file under `agent-factory/openclaw/templates/`, `agent-factory/roles/` or `skills/` contains the author's first name
- **THEN** the gate flags it as `author-name-in-rendered-text`

### Requirement: Genericising never changes behaviour

Wording edits to roles, templates, scripts and `roster.json` MUST NOT change code lines, data keys or values consumed by code, and composed output SHALL remain free of drift.

#### Scenario: Compose output unchanged

- **WHEN** the genericising edits are applied
- **THEN** `compose.py --check` reports no drift for the core, grid and finance-desk projects and the existing roster test passes
