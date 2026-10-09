## Purpose

Define where instincts live, how they are scoped to a project across machines, how several machines write without git conflicts, and when an instinct becomes global. The store is private; the public repo holds none of it.

## ADDED Requirements

### Requirement: Instincts live in the private repo
The system SHALL store instincts only under `learning/instincts/` in the private repo (overridable by `GRID_LEARNING_DIR`) and MUST NOT write instinct data into the public repo.

#### Scenario: Analysis output location
- **WHEN** the analyser writes an instinct
- **THEN** the file is under `<GRID_LEARNING_DIR>/instincts/<project-id>/`

### Requirement: Projects are identified by a hash of the git remote
The system SHALL derive the project id as the first 12 hex characters of the SHA-256 of the normalised origin URL, so the same repository has the same id on every machine regardless of URL style.

#### Scenario: Equivalent remotes
- **WHEN** one machine uses `git@github.com:Owner/Repo.git` and another uses `https://github.com/owner/repo`
- **THEN** both compute the same project id

#### Scenario: Credentials in the URL
- **WHEN** the remote is `https://user:token@github.com/owner/repo.git`
- **THEN** the id equals that of the same URL without credentials

### Requirement: Each host writes only its own files
The system SHALL write instincts to a file named for the writing host and MUST merge files from all hosts at read time, so concurrent machines never edit the same file.

#### Scenario: Two hosts, same instinct
- **WHEN** two hosts each hold a line for the same instinct id with different confidence
- **THEN** the merged view shows the id once with the higher confidence and the latest `last_seen`

#### Scenario: Retirement wins when newer
- **WHEN** a host retires an id and no active line for it has a later `last_seen`
- **THEN** the merged view treats the id as retired

### Requirement: Instincts are validated and bounded
The system SHALL accept an instinct only if its id matches `^[a-z0-9][a-z0-9-]{1,46}[a-z0-9]$`, its trigger is at most 120 characters, its action at most 200, and neither contains a URL, a backtick or a newline.

#### Scenario: Oversized action
- **WHEN** an instinct line has a 300-character action
- **THEN** validation rejects it and it is never written or injected

### Requirement: Instincts are promoted to global on evidence from two projects
The system SHALL promote an instinct to global scope when the same id is active with confidence at least 0.5 in at least two distinct projects, using the lowest contributing confidence.

#### Scenario: Promotion
- **WHEN** id `bats-for-shell-tests` is active at 0.6 in project A and 0.75 in project B
- **THEN** a global line for that id exists with confidence 0.6

#### Scenario: Re-running promotion
- **WHEN** promotion runs a second time with no changes
- **THEN** the global file is byte-identical

### Requirement: The operator can inspect, retire and forget
The system SHALL provide `show`, `retire <id>` and `forget <project-id> --yes` commands, and `forget` MUST delete nothing without `--yes`.

#### Scenario: Forget without confirmation
- **WHEN** `forget <project-id>` is run without `--yes`
- **THEN** no file is deleted
