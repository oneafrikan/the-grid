## Purpose

Make malformed, over-promoted, edited or dangling knowledge fail the commit gate, by extending `scripts/map.py --check` to lint `signals/` and `knowledge/` with the single parser in `scripts/knowledge.py` (A2).

## ADDED Requirements

### Requirement: One check, three exit codes
`scripts/map.py --check` SHALL run the MAP.md drift check (A1) and the knowledge lint below, write nothing, and exit 0 when both are clean, 1 on any drift or lint finding, 2 when it could not run. Each lint finding SHALL be one line `E_<CODE> <path>[:<line>]: <message>` with a stable code, sorted by path.

#### Scenario: Clean tree
- **WHEN** MAP.md is current and every linted file is well formed
- **THEN** the command prints no `E_` line and exits 0

#### Scenario: Unreadable file
- **WHEN** a linted file cannot be read
- **THEN** the command exits 2 and names the file

#### Scenario: Read-only
- **WHEN** the command runs on a tree with findings
- **THEN** `git status --porcelain` is unchanged afterwards

### Requirement: Single grammar, no second parser
The lint SHALL parse signals, entries and ledger lines only through functions in `scripts/knowledge.py`; `map.py` SHALL NOT carry its own frontmatter parser or its own warrant, hash or address rules.

#### Scenario: No duplicate definition
- **WHEN** `scripts/map.py` is searched for a frontmatter regex, the warrant stop-word list or the hash routine
- **THEN** none is defined there; they are imported

#### Scenario: Grammar change reaches the lint
- **WHEN** a field is added to the signal grammar in `knowledge.py`
- **THEN** `map.py --check` applies it with no edit to `map.py`

### Requirement: Stage enum and layout
The lint SHALL fail an entry or signal whose `stage` is not one of `wip`, `provisional`, `established`, `canonical`, `superseded`, `retired` (a signal's stage is a proposal; any of the six is valid), an entry whose `stage` disagrees with its directory (`canonical` lives in `knowledge/canon/`, every other stage in the directory of its own name), and any file in `knowledge/canon/` whose stage is not `canonical`.

#### Scenario: Unknown stage
- **WHEN** an entry has `stage: draft`
- **THEN** the output contains `E_STAGE` with that path

#### Scenario: Canonical outside canon
- **WHEN** `knowledge/established/K-x.md` has `stage: canonical`
- **THEN** the output contains `E_STAGE` naming both the stage and the directory

#### Scenario: Wrong stage in canon
- **WHEN** `knowledge/canon/K-y.md` has `stage: established`
- **THEN** the output contains `E_STAGE`

#### Scenario: Signal proposes a human-set stage
- **WHEN** a signal has `stage: canonical` or `stage: retired`
- **THEN** no `E_STAGE` line appears for the signal

### Requirement: Signals are well formed and unedited
The lint SHALL fail a file in `signals/` or `signals/done/` that breaks the signal grammar (required keys, one-line limits, hidden characters, unknown or repeated keys, body size) or that has been modified after the commit that added it (in history, or in the index or working tree). `<hash6>` is any six hex characters and SHALL NOT be compared with the file content. Without git the history check SHALL be skipped with one notice. It SHALL ignore `signals/README.md` and `signals/→*.md`. A `signals/done/` file SHALL have a `disposition` line in `signals/done/ledger.jsonl`, and a `signals/*.md` pending file SHALL NOT.

#### Scenario: Missing required key
- **WHEN** a pending signal has no `filed_by`
- **THEN** the output contains `E_SIGNAL` naming the file and the key

#### Scenario: Edited after commit
- **WHEN** a signal added in an earlier commit has its body changed
- **THEN** the output contains `E_EDITED`

#### Scenario: Hand-filed signal
- **WHEN** a signal is written by hand with `hash6` `a1b2c3` that is not a hash of its content
- **THEN** no `E_` line appears for it

#### Scenario: Sweep move
- **WHEN** the sweep renames a signal into `signals/done/` unchanged
- **THEN** no `E_EDITED` line appears

#### Scenario: No git
- **WHEN** the check runs outside a git repository
- **THEN** it prints one notice, skips the history check and applies every other rule

#### Scenario: Handoff files
- **WHEN** `signals/→tech-lead.md` and `signals/README.md` exist
- **THEN** neither is reported

#### Scenario: Done without ledger line
- **WHEN** `signals/done/<name>.md` has no `disposition` line in the ledger
- **THEN** the output contains `E_LEDGER`

#### Scenario: Processed but still pending
- **WHEN** a ledger `disposition` line names a file still in `signals/`
- **THEN** the output contains `E_LEDGER`

### Requirement: Warrant and the different-filer rule hold in the tree
The lint SHALL fail an entry above `wip` that is marked `unwarranted: yes` or whose evidence has no warranted line, and SHALL fail a `provisional` or `established` entry whose stage exceeds the ceiling from its evidence (one distinct warranted `filed_by` for `provisional`, two for `established`). Entries at `canonical`, `superseded` and `retired` are human-set and are not checked against the ceiling.

#### Scenario: Promoted without warrant
- **WHEN** an entry has `stage: provisional` and `unwarranted: yes`
- **THEN** the output contains `E_WARRANT`

#### Scenario: Established by one filer
- **WHEN** an `established` entry's evidence lists two lines from the same `filed_by`
- **THEN** the output contains `E_WARRANT`

#### Scenario: Hand-edited promotion
- **WHEN** a `wip` entry's stage and directory are changed to `established` in a commit with no new evidence line
- **THEN** the output contains `E_WARRANT`

#### Scenario: Wip without warrant
- **WHEN** an entry has `stage: wip` and `unwarranted: yes`
- **THEN** no `E_WARRANT` line appears for it

### Requirement: Addresses resolve
The lint SHALL resolve every address in the frontmatter fields `supersedes`, `superseded_by`, `contradicts`, `confirms` and `guardrail` of signals and entries. Forms: `K-<hash8>[#slug]` (exactly one matching entry, slug is a heading in it), `GUARDRAILS#G<n>` (a rule ID defined in `GUARDRAILS.md`), and `<path>[#slug]` (file exists as written or with `.md` appended; slug matches a heading by GitHub rules). An address into `signals/`, with a leading `/` or with `..` SHALL fail. A `K-` address SHALL still resolve after its entry moves between stage directories.

#### Scenario: Guardrail citation
- **WHEN** a signal has `guardrail: GUARDRAILS#G3` and `GUARDRAILS.md` defines `G3`
- **THEN** no `E_ADDR` line appears

#### Scenario: Dangling anchor
- **WHEN** a signal cites `GUARDRAILS#G9` and no `G9` exists
- **THEN** the output contains `E_ADDR` naming the address

#### Scenario: Entry address after promotion
- **WHEN** an entry cited as `K-1a2b3c4d#evidence` moves from `provisional/` to `established/`
- **THEN** no `E_ADDR` line appears

#### Scenario: Missing entry
- **WHEN** `supersedes: K-deadbeef` matches no file
- **THEN** the output contains `E_ADDR`

#### Scenario: Ambiguous entry
- **WHEN** two files match one `K-<hash8>`
- **THEN** the output contains `E_ADDR` listing both

#### Scenario: Escaping address
- **WHEN** an address is `../outside.md` or points into `signals/`
- **THEN** the output contains `E_ADDR`

### Requirement: Feature detection and portability
The lint SHALL do nothing, and say so in one notice line, when `scripts/knowledge.py` is absent or neither `signals/` nor `knowledge/` exists. It SHALL need only the system `python3` (3.8 syntax, no third-party package, no network); git is used only for the history check. The project-template copy of `knowledge.py` is A2's (with its `cmp` test); this change adds no mirror.

#### Scenario: Project without knowledge.py
- **WHEN** `map.py --check` runs in a tree with `signals/` but no `scripts/knowledge.py`
- **THEN** it prints one notice, runs only the drift check, and exits by that result

#### Scenario: No venv
- **WHEN** the check runs with only the system `python3` and no agent-factory venv
- **THEN** it completes with exit 0 on a clean tree

### Requirement: The existing gate check carries the lint
`scripts/gate.sh` SHALL fail its existing `map` check (A1) on any lint finding and SHALL NOT gain a second map check. The `map` check SHALL NOT be added to `GRID_GATE_EXPECT_SKIPPED` in CI.

#### Scenario: Lint failure fails the gate
- **WHEN** a signal has `stage: draft`
- **THEN** `gate.sh` prints FAIL for `map` and exits non-zero

#### Scenario: Interpreter absent
- **WHEN** `gate.sh` runs without `python3` on PATH
- **THEN** `map` is listed as skipped and does not fail the gate
