## Purpose

Make skill and role counts a generated fact so README and the landing page can never disagree with the catalogue.

## ADDED Requirements

### Requirement: Stats file from the catalogue
catalog.sh SHALL write `docs/stats.json` with the keys indexed, library, roles, root_owned, upstream_wired and wired, deterministically.

#### Scenario: Stats written
- **WHEN** `catalog.sh` runs against a fixture repo
- **THEN** `docs/stats.json` holds the same totals printed in the SKILLS.md headline and the roles count equals the `- role:` lines in agent-factory/examples
- **AND** a second run produces a byte-identical file

#### Scenario: Catalog check covers stats
- **WHEN** `catalog.sh --check` runs after `docs/stats.json` is edited by hand
- **THEN** it exits non-zero and names stats.json

### Requirement: Marker stamping
scripts/stamp-counts.py SHALL replace the value inside every `<!--count:NAME-->...<!--/count-->` marker in README.md, README.*.md and index.html with the matching stats.json value, idempotently.

#### Scenario: Stamp and re-stamp
- **WHEN** stamp-counts.py runs twice on files with stale values
- **THEN** the first run updates them and the second changes nothing

#### Scenario: Unknown name
- **WHEN** a marker names a key not in stats.json
- **THEN** the script exits 2 and names the marker

### Requirement: Drift fails the gate
gate.sh SHALL fail when any stamped file disagrees with docs/stats.json.

#### Scenario: Stale number
- **WHEN** a marker value in README.md differs from stats.json
- **THEN** `stamp-counts.py --check` exits 1 and the gate reports FAIL for counts

### Requirement: No typed headline counts
README.md and index.html SHALL NOT contain a bare number of two to four digits directly before the words skills, agents or roles outside a count marker.

#### Scenario: Typed number rejected
- **WHEN** the front-door test scans README.md and index.html
- **THEN** it fails if "137 skills" appears outside a marker
