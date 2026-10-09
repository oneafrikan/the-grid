## Purpose

Define what a first-time visitor sees in README.md and where maintainer material lives, so the message arrives before the mechanics.

## ADDED Requirements

### Requirement: Hero sentence and status line
The README SHALL open with the project name, then the approved hero sentence as a bold paragraph (not a blockquote) that names no third-party tool, followed by a one-line statement of what ships today.

#### Scenario: Hero is present and plain
- **WHEN** README.md is read from the top
- **THEN** the exact hero sentence appears once, outside any `>` quote line
- **AND** the hero sentence contains none of "Claude Code", "ECC", "gstack"
- **AND** a "works today with Claude Code" status line follows within the first 12 lines

### Requirement: Section order and length
The README SHALL be between 140 and 185 lines and SHALL present Who it's for, Quickstart, What you get, How it works, Why "the grid", Status and Docs as `##` sections in that order.

#### Scenario: Structure test
- **WHEN** the front-door test counts lines and lists `##` headings
- **THEN** the count is within bounds
- **AND** the headings occur in the required order

### Requirement: Audience stated high
The README SHALL state who the project is for and who it is not for in the first `##` section.

#### Scenario: Audience section first
- **WHEN** the `##` headings are listed
- **THEN** "Who it's for" is first
- **AND** it contains at least three "for you" bullets and one "not for you" bullet

### Requirement: Copy-paste quickstart with verification
The README SHALL give a quickstart command that uses the real clone URL, enables the agent teams, and lists the observable results of a successful run.

#### Scenario: Real URL, no placeholder
- **WHEN** the quickstart section is read
- **THEN** it contains `git clone https://github.com/oneafrikan/the-grid.git ~/.the-grid` and `bootstrap.sh --with-agents`
- **AND** no file in the repo contains `<your-username>`

#### Scenario: Verification step
- **WHEN** the quickstart section is read
- **THEN** it lists the bootstrap completion message, the skills-directory check, and the expected `/tron` behaviour

### Requirement: Architecture diagram
The README SHALL include a mermaid flowchart showing sources, the allowlist, wire.sh and compose.py, the symlink targets, and the library path.

#### Scenario: Diagram present
- **WHEN** README.md is scanned for fenced blocks
- **THEN** one block has the language `mermaid` and mentions `wire.sh` and `compose.py`

### Requirement: Tron identity retained
The README SHALL keep the ASCII banner and the Flynn monologue with attribution, placed after the hero message.

#### Scenario: Banner and quote present, not first
- **WHEN** README.md is read
- **THEN** the ASCII banner and "Kevin Flynn" attribution are present
- **AND** the banner appears after the hero sentence and the monologue appears after the "How it works" section

### Requirement: Maintainer material relocated
The repository SHALL hold maintainer documentation in INSTALL.md, CONTRIBUTING.md, docs/architecture.md, docs/roadmap.md and docs/private-projects.md, and every relative link in README.md and those files SHALL resolve.

#### Scenario: Links resolve
- **WHEN** the link test runs over README.md and the five relocated docs
- **THEN** every relative link target exists

#### Scenario: Nothing lost
- **WHEN** the previous README's section list is compared with the new files
- **THEN** each section is found in exactly one new location
