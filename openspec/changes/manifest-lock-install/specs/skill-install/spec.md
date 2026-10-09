## Purpose

Let any machine get the locked skill set with no submodule clones, using only HTTPS and git, with every byte verified against the lock and vetted before it is placed.

## ADDED Requirements

### Requirement: grid install fetches only locked skills and verifies them
`grid install` SHALL, without cloning any submodule, fetch only the selected locked skill directories over HTTPS at each entry's pinned sha, verify commit sha, tree id and content hash against `grid.lock`, place each verified directory at `repos/<source>/<path>` only when `repos/<source>` is not a git checkout, and then run `wire.sh` with `GRID_NO_CATALOG=1` so the tracked `SKILLS.md` is not rewritten.

#### Scenario: Fresh machine install
- **WHEN** `grid install` runs on a clone with no initialised submodules
- **THEN** each selected skill exists under `repos/<source>/<path>` with a `SKILL.md`, no `repos/*` directory contains a `.git`, `git status` shows no change to tracked files, and the skills dir contains a link per wired skill

#### Scenario: Re-run is a no-op
- **WHEN** `grid install` is run a second time with an unchanged lock
- **THEN** no fetch occurs, the placed files and ledger are unchanged, and it exits 0

#### Scenario: Hash mismatch fails that skill
- **WHEN** the fetched content hash differs from the lock
- **THEN** nothing for that skill is placed, the error names the skill, and `grid install` exits 1

#### Scenario: Unsafe lock entry rejected
- **WHEN** a `grid.lock` entry has a `path` or `source` that is absolute, contains `..`, starts with `-` or contains a space, or a `sha` that is not 40 hex characters
- **THEN** `grid install` exits 2 naming the entry before any network access, and nothing is created outside the grid directory

#### Scenario: Existing directory not overwritten
- **WHEN** `repos/<source>/<path>` already exists, is not in the ledger and its content differs from the lock, or a placed directory has been edited
- **THEN** it is left untouched, named in an error and `grid install` exits 1; with `--force` it is replaced

#### Scenario: Matching directory adopted
- **WHEN** `repos/<source>/<path>` exists, is not in the ledger and its content hash equals the lock
- **THEN** it is recorded in the ledger with no fetch

#### Scenario: Dry run
- **WHEN** `grid install --dry-run` runs
- **THEN** it prints what would be fetched, placed and removed, makes no network access and writes no file

#### Scenario: Symlinked grid directory
- **WHEN** the grid directory is reached through a symlinked path
- **THEN** the install, its links and the ledger behave exactly as through the real path

#### Scenario: Machine overlay subtraction honoured
- **WHEN** the machine overlay contains `-<source>/<skill>`
- **THEN** that skill is not fetched and not wired

#### Scenario: Runtime source skipped
- **WHEN** a selected source is listed in `scripts/lib/runtimes.txt`
- **THEN** none of its entries is fetched, a notice gives the maintainer-path commands for that source, and the exit status is unaffected

#### Scenario: Maintainer checkout untouched
- **WHEN** `repos/<source>/.git` exists
- **THEN** `grid install` writes nothing under `repos/<source>` and prints a notice

### Requirement: Staged content is vetted before placement
`grid install` and `grid repair` SHALL run `scripts/audit.py --format json` on the staged copy with paths reported as `repos/<source>/...`, MUST NOT place an entry that has an un-allowed high-severity finding unless `GRID_AUDIT=warn`, and `grid audit` SHALL pass its arguments to `scripts/audit.sh` and return its exit code.

#### Scenario: Unsafe skill blocked, sibling placed
- **WHEN** one staged skill contains a line matching a high-severity policy rule and another skill of the same source is clean
- **THEN** the clean skill is placed, the unsafe one is not, the finding is printed, and `grid install` exits 1

#### Scenario: Warn mode
- **WHEN** the same install runs with `GRID_AUDIT=warn`
- **THEN** both skills are placed and a warning names the unsafe one

#### Scenario: Allowlisted finding passes
- **WHEN** the finding is allowlisted in `CURATION.md` for its `repos/<source>/...` path
- **THEN** the skill is placed

#### Scenario: Scanner missing
- **WHEN** `scripts/audit.py` or `policy.yaml` is absent from the grid directory and `GRID_AUDIT` is not `warn`
- **THEN** `grid install` exits 2 with `refusing to place unvetted content` before any network access and places nothing; with `GRID_AUDIT=warn` it places the entries and prints an audit SKIPPED notice

#### Scenario: Source not allowed by policy
- **WHEN** a selected source's `https://` URL fails `audit.py --check-url`
- **THEN** `grid install` exits 2 naming the source before any network access

#### Scenario: Symlink escape caught at placement
- **WHEN** a staged skill directory contains a symlink whose target resolves outside the skill directory, or its content hash recomputed on the copy about to be placed differs from the lock
- **THEN** that entry is not placed, the error names it, and `grid install` exits 1

#### Scenario: Audit passthrough
- **WHEN** `grid audit --wired` runs
- **THEN** it runs `scripts/audit.sh --wired` and exits with that script's exit code
