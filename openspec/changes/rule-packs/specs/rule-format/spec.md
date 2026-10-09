## Purpose

Define the source format for path-scoped coding rule packs and the lint that keeps packs small, sourced, attributed and free of imported house opinions.

## ADDED Requirements

### Requirement: Path-scoped, size-capped rule files
Every rule file under `rules/<pack>/` (any `*.md` other than `README.md`) SHALL have frontmatter containing exactly one key, `paths`, with at least one glob that is not `*`, `**`, `**/*`, absolute, or containing `..`, and lint MUST fail any rule file over 4096 bytes or any pack whose rule files total over 9216 bytes.

#### Scenario: Rule without paths is rejected
- **WHEN** `rules.py lint` runs on a pack containing a rule file with no `paths:` frontmatter
- **THEN** it exits non-zero and reports `E_FRONTMATTER` or `E_PATHS` for that file

#### Scenario: Catch-all glob is rejected
- **WHEN** a rule file declares `paths` of `"**/*"`
- **THEN** lint exits non-zero and reports `E_PATHS`

#### Scenario: Extra frontmatter key is rejected
- **WHEN** a rule file's frontmatter contains a key other than `paths`
- **THEN** lint exits non-zero and reports `E_FRONTMATTER`

#### Scenario: Oversized file
- **WHEN** a rule file is 4097 bytes
- **THEN** lint reports `E_FILE_SIZE` and exits non-zero

#### Scenario: Oversized pack
- **WHEN** a pack's rule files total 9217 bytes with each file under the per-file cap
- **THEN** lint reports `E_PACK_SIZE` and exits non-zero

### Requirement: Opinion-free, sourced and attributed packs
Lint SHALL fail any rule file matching a case-insensitive regex in `rules/denylist.txt`, any pack lacking `pack.yaml` (`summary`, `tier`) or a README Sources row with an https URL per rule file, and any tier 2 pack lacking the README line `Adapted from affaan-m/ECC (MIT)`, an `adapted_from` key, or an entry in `rules/THIRD_PARTY_NOTICES.txt`.

#### Scenario: Imported house opinion
- **WHEN** a rule file contains the text `ALWAYS create new objects`
- **THEN** lint reports `E_OPINION` naming the file and the matching pattern

#### Scenario: Legitimate technical wording passes
- **WHEN** a rule file says "inline critical CSS" and "the query planner"
- **THEN** lint reports no `E_OPINION` finding for those phrases

#### Scenario: Rule file without a source row
- **WHEN** a pack README's Sources table has no row with an https URL for `style.md`
- **THEN** lint reports `E_SOURCES`

#### Scenario: Adapted pack without attribution
- **WHEN** a pack declares `tier: 2` but its README lacks the attribution line
- **THEN** lint reports `E_ATTRIBUTION`

#### Scenario: Tier and adapted_from disagree
- **WHEN** a pack declares `tier: 1` and also has an `adapted_from` key
- **THEN** lint reports `E_PACK_META`

### Requirement: Lint is part of the offline commit gate
`scripts/gate.sh` SHALL run `python3 scripts/rules.py lint` and MUST NOT make network calls for it.

#### Scenario: Gate fails on a bad pack
- **WHEN** a pack violates any lint check and `bash scripts/gate.sh` runs
- **THEN** the gate output shows a failing `rules` check and exits non-zero

#### Scenario: URL checking is opt-in
- **WHEN** the gate runs offline
- **THEN** no Sources URL is fetched; only `rules.py lint --check-urls` does that
