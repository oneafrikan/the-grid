## Purpose

Define where accepted knowledge lives, in what format, how it is addressed, and how it is superseded, so a reader can tell at a glance what is canon.

## ADDED Requirements

### Requirement: Layout by stage
A project repo SHALL keep knowledge in `knowledge/` with one directory per stage: `wip/`, `provisional/`, `established/`, `canon/` (stage `canonical`), `superseded/`, `retired/`. An entry's `stage` frontmatter value SHALL agree with its directory. `knowledge/canon/` SHALL hold canonical entries only. Each directory SHALL be seeded with a `.gitkeep`, and `knowledge/README.md` SHALL describe the layout.

#### Scenario: Seeded layout
- **WHEN** a project is cut from `_common`
- **THEN** `knowledge/README.md` and the six stage directories exist

#### Scenario: Stage and directory disagree
- **WHEN** an entry with `stage: canonical` sits in `knowledge/established/`
- **THEN** `knowledge.py check` fails and names the file

### Requirement: Entry format
An entry SHALL be `knowledge/<dir>/K-<hash8>-<slug>.md` where `<hash8>` is the first 8 hex of the claim hash and `<slug>` is the claim reduced to `[a-z0-9-]`, at most 40 characters. It SHALL hold flat frontmatter `id`, `claim`, `claim_hash` (16 hex), `stage`, `created`, `updated` (UTC dates), optionally `supersedes`, `superseded_by`, `contradicts`, `guardrail`, `unwarranted: yes`; then `## Claim` (the claim text) and `## Evidence` with one line per supporting signal: `- <signal filename> | <filed_by> | <claimed stage> | <warrant>`. An entry SHALL NOT contain signal body text.

#### Scenario: New entry
- **WHEN** the sweep writes a first entry for a warranted signal
- **THEN** the file has the frontmatter above, one evidence line, and `stage: provisional` at most

#### Scenario: Unwarranted entry
- **WHEN** the entry is written from a signal with no warrant
- **THEN** it has `stage: wip`, `unwarranted: yes` and its evidence line records the warrant as written

### Requirement: Stable addresses
An entry SHALL be cited by `K-<hash8>` or `K-<hash8>#<heading-slug>` (`claim`, `evidence`), resolved by matching `knowledge/*/K-<hash8>-*.md`. The path form `knowledge/<dir>/K-<hash8>-<slug>.md[#slug]` SHALL be valid only while the file is at that path. An address that matches zero files or more than one file, or a slug with no such heading, SHALL fail loudly: `knowledge.py check --address ADDR` exits 1 with the reason.

#### Scenario: Entry promoted
- **WHEN** an entry moves from `provisional/` to `established/`
- **THEN** `K-<hash8>#evidence` still resolves

#### Scenario: Missing heading
- **WHEN** `K-<hash8>#notes` is checked
- **THEN** it exits 1 with "no heading notes"

#### Scenario: Ambiguous id
- **WHEN** two files match one `K-<hash8>`
- **THEN** it exits 1 and lists both

### Requirement: Stage is a function of evidence
The sweep SHALL set an entry's stage to the lower of the highest stage claimed by its evidence and the ceiling from its warranted evidence (no warranted filer: `wip`; one distinct warranted `filed_by`: `provisional`; two or more: `established`), and SHALL NOT lower a stage automatically. The sweep SHALL NOT set `canonical` or `superseded`, and SHALL NOT write into `knowledge/canon/`, `knowledge/superseded/` or `knowledge/retired/` on the sweep branch.

#### Scenario: Established needs a second filer
- **WHEN** an entry has one warranted filer and the sweep sees a second signal from a different filer with its own warrant and the same claim hash or `confirms` pointing at the entry
- **THEN** evidence has two lines and the entry moves to `established/`

#### Scenario: Same filer again
- **WHEN** the second signal has a `filed_by` that already has a warranted evidence line
- **THEN** no evidence line is added

#### Scenario: Filer adds the missing warrant
- **WHEN** a filer whose earlier signal had no warrant files the same claim with a warrant
- **THEN** a warranted evidence line is added and the entry may move from `wip` to `provisional`

#### Scenario: Copied warrant
- **WHEN** the second filer's warrant equals an existing warrant case-insensitively
- **THEN** it does not count as a confirmation and the signal is a `duplicate`

### Requirement: Supersede handling
Superseding SHALL be done only in a human-approved change: the new entry carries `supersedes: K-old`; the old entry moves to `knowledge/superseded/` and carries `superseded_by: K-new`; both change in one PR. A superseded entry SHALL remain in the repo and keep resolving by address. Superseded and retired entries SHALL NOT appear in the canon list.

#### Scenario: Proposal
- **WHEN** a signal has `supersedes: K-old`
- **THEN** the sweep opens an issue and a PR containing exactly those two file changes, and changes nothing on the sweep branch

#### Scenario: Cross-link check
- **WHEN** an entry has `superseded_by: K-new` but K-new lacks `supersedes: K-old`
- **THEN** `knowledge.py check` fails

### Requirement: Retirement is human
An entry SHALL be retired only by a human-authored change that moves it to `knowledge/retired/` with `stage: retired`. No signal claims `retired`.

#### Scenario: Retired claim in a signal
- **WHEN** a signal has `stage: retired`
- **THEN** it is `invalid`

### Requirement: Canon changes only by human-approved PR
No automatic process SHALL write to `knowledge/canon/` except by opening a PR. The sweep SHALL NOT merge, auto-merge or close that PR. The standing approval to merge fix PRs into `next` on green CI plus independent QA SHALL NOT apply to a PR touching `knowledge/canon/`.

#### Scenario: Sweep run with a canonical claim
- **WHEN** a pending signal claims `canonical`
- **THEN** after the run `knowledge/canon/` on the sweep branch is unchanged and a PR exists proposing the entry

### Requirement: Fields consumed by the map
Each entry SHALL expose `id`, `claim` and `stage` in frontmatter so `MAP.md` can list entries by stage and one line per canonical entry. `knowledge.py` SHALL be the single parser for signals and entries; the A3 map generator imports it.

#### Scenario: Map reads a canon entry
- **WHEN** the map generator parses `knowledge/canon/K-...md`
- **THEN** it obtains `id`, `claim` and `stage: canonical` from the shared parser without its own regex
