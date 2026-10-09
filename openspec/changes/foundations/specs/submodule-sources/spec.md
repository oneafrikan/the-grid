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

### Requirement: Every example baseline entry resolves
Every positive entry in `baseline-submodules.example.txt` MUST resolve (a `<repo>/<skill>` line to a skill dir discovered in `repos/<repo>`, a whole-repo line to an existing `repos/<repo>`), and every section header with per-skill entries MUST state their true count.

#### Scenario: Renamed upstream skill
- **WHEN** a `<repo>/<skill>` entry in any repo has no matching skill dir
- **THEN** the test fails and names the entry

#### Scenario: Count matches
- **WHEN** a section header says `(N skills)` and its repo has per-skill lines
- **THEN** exactly N lines start with `<repo>/`

#### Scenario: Subtraction and project lines
- **WHEN** a line starts with `-` or `project:`
- **THEN** it is not checked
