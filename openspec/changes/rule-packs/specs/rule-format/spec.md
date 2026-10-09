## Purpose

Define the source format for path-scoped coding rule packs and the lint that keeps packs small, sourced, attributed and free of imported house opinions.

## ADDED Requirements

### Requirement: Path-scoped rule files
Every rule file under `rules/<pack>/` (any `*.md` other than `README.md`) SHALL have frontmatter containing exactly one key, `paths`, with at least one glob that is not `*`, `**`, `**/*`, absolute, or containing `..`.

#### Scenario: Rule without paths is rejected
- **WHEN** `rules.py lint` runs on a pack containing a rule file with no `paths:` frontmatter
- **THEN** it exits non-zero and reports `E_FRONTMATTER` or `E_PATHS` for that file

#### Scenario: Catch-all glob is rejected
- **WHEN** a rule file declares `paths` of `"**/*"`
- **THEN** lint exits non-zero and reports `E_PATHS`

#### Scenario: Extra frontmatter key is rejected
- **WHEN** a rule file's frontmatter contains a key other than `paths`
- **THEN** lint exits non-zero and reports `E_FRONTMATTER`

### Requirement: Size caps
Lint MUST fail any rule file larger than 4096 bytes and any pack whose rule files total more than 9216 bytes.

#### Scenario: Oversized file
- **WHEN** a rule file is 4097 bytes
- **THEN** lint reports `E_FILE_SIZE` and exits non-zero

#### Scenario: Oversized pack
- **WHEN** a pack's rule files total 9217 bytes with each file under the per-file cap
- **THEN** lint reports `E_PACK_SIZE` and exits non-zero

### Requirement: Opinion denylist
Lint SHALL fail any rule file whose text matches a case-insensitive regex in `rules/denylist.txt`.

#### Scenario: Imported house opinion
- **WHEN** a rule file contains the text `ALWAYS create new objects`
- **THEN** lint reports `E_OPINION` naming the file and the matching pattern

#### Scenario: Legitimate technical wording passes
- **WHEN** a rule file says "inline critical CSS" and "the query planner"
- **THEN** lint reports no `E_OPINION` finding for those phrases

### Requirement: Hidden text rejection
Lint MUST reject zero-width, bidirectional-control and byte-order-mark characters in any file inside a pack directory.

#### Scenario: Zero-width character
- **WHEN** a rule file contains U+200B
- **THEN** lint reports `E_UNICODE` and exits non-zero

### Requirement: Sourced and attributed packs
Every pack SHALL have `pack.yaml` (with `summary` and `tier`) and a `README.md` whose Sources table gives an https URL for each rule file, and each tier 2 pack MUST carry the line `Adapted from affaan-m/ECC (MIT)` in its README, an `adapted_from` key, and an entry in `rules/THIRD_PARTY_NOTICES.txt`.

#### Scenario: Rule file without a source row
- **WHEN** a pack README's Sources table has no row with an https URL for `style.md`
- **THEN** lint reports `E_SOURCES`

#### Scenario: Adapted pack without attribution
- **WHEN** a pack declares `tier: 2` but its README lacks the attribution line
- **THEN** lint reports `E_ATTRIBUTION`

#### Scenario: Tier and adapted_from disagree
- **WHEN** a pack declares `tier: 1` and also has an `adapted_from` key
- **THEN** lint reports `E_PACK_META`

### Requirement: Lint is part of the commit gate
`scripts/gate.sh` SHALL run `python3 scripts/rules.py lint` and MUST NOT make network calls for it.

#### Scenario: Gate fails on a bad pack
- **WHEN** a pack violates any lint check and `bash scripts/gate.sh` runs
- **THEN** the gate output shows a failing `rules` check and exits non-zero

#### Scenario: URL checking is opt-in
- **WHEN** the gate runs offline
- **THEN** no Sources URL is fetched; only `rules.py lint --check-urls` does that
