## Purpose

Keep submodule sources reachable on any machine without credentials, keep the wired gstack pin current, and keep the example baseline truthful.

## ADDED Requirements

### Requirement: Public submodules use HTTPS URLs
Every submodule URL in `.gitmodules` whose upstream is public SHALL use the `https://` form.

#### Scenario: No SSH URLs remain
- **WHEN** `.gitmodules` is parsed
- **THEN** no URL begins with `git@` or `ssh://`

#### Scenario: Sources doc carries no SSH marker
- **WHEN** `docs/SOURCES.md` is read
- **THEN** it contains no SSH-form marker or footnote

### Requirement: gstack pin has a version floor
The gstack submodule SHALL be pinned to a commit whose `VERSION` file is at least 1.91.

#### Scenario: Pin at or above the floor
- **WHEN** `repos/gstack/VERSION` is read
- **THEN** its major.minor is 1.91 or higher

#### Scenario: Submodule not initialised
- **WHEN** `repos/gstack` is empty
- **THEN** the version test is skipped

### Requirement: Example baseline gstack section is accurate
The gstack header count in `baseline-submodules.example.txt` MUST equal the number of `gstack/` entries, and each entry SHALL resolve to a discovered skill.

#### Scenario: Count matches
- **WHEN** the header says `(N skills)`
- **THEN** exactly N lines start with `gstack/`

#### Scenario: Entry does not resolve
- **WHEN** a `gstack/<skill>` entry has no matching skill dir in `repos/gstack`
- **THEN** the test fails and names the entry
