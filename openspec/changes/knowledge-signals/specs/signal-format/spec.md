## Purpose

Define the file an agent or human leaves to say "this is true, and here is why", so it can be filed from any machine, never conflicts, never changes, and carries no secret.

## ADDED Requirements

### Requirement: One immutable file per signal with a collision-free name
A signal SHALL be one markdown file in the `signals/` directory of the project's own repo, named `YYYYMMDDTHHMMSSZ-<filer>-<hash6>.md`, where the timestamp is UTC, `<filer>` is the slug of `filed_by` (`[a-z0-9-]{1,32}`) and `<hash6>` is six lowercase hex characters (the helper uses the first six of the SHA-256 of the content; a hand-written file may use any six, so a filer with no shell is not blocked). A signal SHALL NOT be edited after it is committed. Only the knowledge sweep SHALL move it, unchanged, to `signals/done/`.

#### Scenario: Two machines file at once
- **WHEN** two machines each commit a signal in the same second under different `filed_by`
- **THEN** the file names differ and both merge without conflict

#### Scenario: Identical content, same second, same filer
- **WHEN** the helper files the same content twice
- **THEN** the file name is identical and git sees one file

#### Scenario: Edit attempt
- **WHEN** a pending signal has been modified in any commit after the commit that added it
- **THEN** `knowledge.py check` reports it and the sweep treats it as `invalid`

#### Scenario: Processing keeps the bytes
- **WHEN** the sweep processes a signal
- **THEN** `signals/done/<same name>` has byte-identical content and `status: pending` is unchanged in it

### Requirement: Fixed frontmatter
A signal SHALL begin with a flat frontmatter block (`---` fences, one `key: value` per line) holding `filed_by`, `claim`, `stage`, `warrant` and `status: pending`, and MAY hold `supersedes`, `contradicts`, `confirms` (each one entry address `K-<hash8>`) and `guardrail` (`GUARDRAILS#G<n>`). `claim` SHALL be one line of 1-200 characters, `warrant` one line of 1-300 characters, `stage` one of `wip`, `provisional`, `established`, `canonical`. Control characters and hidden or bidirectional unicode SHALL NOT appear in any value. An unknown key, a missing required key, a repeated key or a body over 4096 bytes SHALL make the signal invalid.

#### Scenario: Valid minimal signal
- **WHEN** a file has the five required keys with valid values
- **THEN** `knowledge.py check` exits 0

#### Scenario: Unknown stage
- **WHEN** `stage: superseded` or `stage: retired` is claimed
- **THEN** the signal is invalid (those stages are set by humans or a merged proposal, not claimed)

#### Scenario: Hidden character in claim
- **WHEN** `claim` contains U+202E or a zero-width space
- **THEN** the signal is invalid and is not cleaned silently

### Requirement: Every claim carries its warrant
`warrant` SHALL state the evidence in one line. The literal values `none`, `n/a`, `na`, `untested`, `unknown`, `tbd` and `?` (case-insensitive) SHALL mean "no warrant". A signal with no warrant SHALL be treated as stage `wip` whatever stage it claims, and SHALL NOT raise any entry's stage.

#### Scenario: Claimed established, no warrant
- **WHEN** a signal claims `established` with `warrant: none`
- **THEN** it is handled as `wip`

### Requirement: Signals contain no secrets
A signal, including its body, SHALL NOT contain a credential, token, key, password or personal data. The convention README SHALL say so. The sweep SHALL scan each pending signal with the strict secret patterns (`SECRET_STRICT=1`, no exemptions, no allow pragma honoured) before using it, and SHALL never print a matched value.

#### Scenario: Committed through Claude Code with the guard on
- **WHEN** a project has `hooks.profile` of `standard` or higher and a Bash `git commit` stages a signal holding a token-shaped value
- **THEN** `pre-bash-secret-scan` blocks the commit (exit 2) and prints file and line, not the value

#### Scenario: Guard off or bypassed
- **WHEN** such a signal reaches the repo anyway
- **THEN** the sweep's strict scan flags it (see knowledge-sweep, secret handling)

#### Scenario: Line-level override in a signal
- **WHEN** a signal line carries the scanner's allow pragma next to a token-shaped value
- **THEN** the sweep's strict scan still flags it

### Requirement: Signals stay in the project's own repo and are private to it
A signal SHALL be committed in the repo of the project it is about, one repo per project, and SHALL NOT be copied to another repo or to the public grid unless the project is the grid itself. Signals filed in the public grid SHALL be about the grid and contain nothing private. Business signals SHALL land in the business repo.

#### Scenario: Public grid
- **WHEN** a signal is filed in the-grid
- **THEN** its claim concerns the grid and nothing in it names a business or person

### Requirement: Filing is by helper or by hand, with the same result
`scripts/knowledge.py file --filer F --claim C --stage S --warrant W [--supersedes ID] [--contradicts ID] [--confirms ID] [--guardrail G] [--body-file P]` SHALL write a valid signal to `signals/` and print its path. It SHALL NOT commit. An agent with no shell MAY write the file by hand to the same format; `<hash6>` of a hand-written file is any six lowercase hex characters. The helper SHALL be present in every seeded project as `scripts/knowledge.py`, byte-identical to the-grid's copy.

#### Scenario: Helper output
- **WHEN** the helper is run with valid arguments
- **THEN** a file with the correct name and `status: pending` exists and `knowledge.py check` passes it

#### Scenario: Seeded project
- **WHEN** a project is cut from `_common`
- **THEN** `scripts/knowledge.py` exists and `cmp` finds it identical to `scripts/knowledge.py` in the-grid

#### Scenario: Hand-written name
- **WHEN** a file is named `20261018T101500Z-human-alex-abc123.md` with valid frontmatter, written without the helper
- **THEN** `knowledge.py check` exits 0

#### Scenario: Invalid argument
- **WHEN** the claim has 201 characters
- **THEN** the helper exits 2 and writes nothing

### Requirement: Coexistence with hand-off files
Only files matching the signal name pattern SHALL be treated as knowledge signals. `signals/README.md`, `signals/done/`, and the `signals/→<agent>.md` hand-off files of the Signal Protocol SHALL be ignored by the sweep, the helper and the lint.

#### Scenario: Hand-off file present
- **WHEN** `signals/→tech-lead.md` exists
- **THEN** `knowledge.py plan` does not list it and `check` does not fail on it

### Requirement: Per-repo convention README
Each project repo SHALL carry `signals/README.md` (seeded by `charter-files`, completed by this change) stating: the name pattern, the frontmatter table, the template, the immutability rule, the no-secrets rule, that only the sweep moves files, that signals stay in this repo, that `→*.md` files are hand-offs, how a sweep is enabled, and the recommendation to set `hooks.profile: standard` in `.grid/project.yaml`. It SHALL retain the six-stage vocabulary and the warrant rule that `charter-files` requires (at most 25 lines for the vocabulary). The `_common` template SHALL carry the same text, and `scripts/cut-project.sh` SHALL seed it and retrofit it without overwriting an existing differing file.

#### Scenario: Seed
- **WHEN** `cut-project.sh` seeds an empty directory from a template
- **THEN** `signals/README.md` contains the name pattern, the frontmatter keys and the no-secrets rule

#### Scenario: Sweep status no longer "none configured"
- **WHEN** `signals/README.md` is read after this change
- **THEN** it says the sweep is the `gh-triage` knowledge sweep, enabled per repo in the gh-triage scope file

#### Scenario: Retrofit with a local variant
- **WHEN** the target already has a different `signals/README.md` (including A1's earlier text)
- **THEN** it is left as is and reported as skipped; the operator updates it by hand
