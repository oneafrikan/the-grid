## Purpose

Make skill and role counts a generated fact so README and the landing page can never disagree with the catalogue.

## ADDED Requirements

### Requirement: Marker stamping from the catalogue
scripts/stamp-counts.py SHALL replace the value inside every `<!--count:NAME-->...<!--/count-->` marker in README.md, README.*.md and index.html with the value parsed from the committed SKILLS.md headline (indexed, wired, root_owned, upstream_wired, library) or the role count from agent-factory/examples (roles), idempotently.

#### Scenario: Stamp and re-stamp
- **WHEN** stamp-counts.py runs twice on files with stale values
- **THEN** the first run writes the SKILLS.md headline numbers and the `- role:` line count
- **AND** the second run changes nothing

#### Scenario: Unknown name
- **WHEN** a marker names a key outside the six known keys
- **THEN** the script exits 2 and names the marker

#### Scenario: Headline format changed
- **WHEN** markers exist and the SKILLS.md headline no longer matches the expected pattern
- **THEN** the script exits 2

### Requirement: Catalogue regeneration restamps
catalog.sh SHALL run stamp-counts.py after writing the default SKILLS.md, and SHALL NOT run it in `--check` mode or when given an output path.

#### Scenario: Wire keeps counts current
- **WHEN** `catalog.sh` regenerates SKILLS.md with a new wired count
- **THEN** the count markers in README.md hold the new number

### Requirement: Drift fails the gate
gate.sh SHALL fail when any stamped file disagrees with the committed SKILLS.md headline or role count.

#### Scenario: Stale number
- **WHEN** a marker value in README.md differs from the SKILLS.md headline
- **THEN** `stamp-counts.py --check` exits 1 and the gate reports FAIL for counts

### Requirement: No typed headline counts
README.md and index.html SHALL NOT contain a bare number of two to four digits directly before the words skills, agents or roles outside a count marker.

#### Scenario: Typed number rejected
- **WHEN** the front-door test scans README.md and index.html
- **THEN** it fails if "137 skills" appears outside a marker
