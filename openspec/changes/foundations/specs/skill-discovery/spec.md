## Purpose

Give `wire.sh`, `catalog.sh` and tests one answer to "which SKILL.md files does this repo ship", ignoring translations and per-harness copies.

## ADDED Requirements

### Requirement: Translation directories are excluded
`find_skill_mds` MUST NOT report a SKILL.md under `docs/`, `i18n/`, `translations/` or `locales/` followed by a locale directory matching `^[a-z]{2}([-_][A-Za-z]{2,4})?$`.

#### Scenario: Locale copy dropped
- **WHEN** a repo has `docs/ja-JP/skills/a/SKILL.md` and `skills/a/SKILL.md`
- **THEN** only `skills/a/SKILL.md` is reported

#### Scenario: Non-locale docs dir kept
- **WHEN** a repo has `docs/guides/a/SKILL.md`
- **THEN** it is reported

### Requirement: Root-level dot-dir copies are excluded
`find_skill_mds` SHALL NOT report a SKILL.md whose first path component starts with a dot.

#### Scenario: Harness copy dropped
- **WHEN** a repo has `.kiro/skills/a/SKILL.md` and `skills/a/SKILL.md`
- **THEN** only `skills/a/SKILL.md` is reported

### Requirement: Listed prefixes are excluded per repo
`find_skill_mds` SHALL NOT report a SKILL.md under a path prefix listed for that repo name in `scripts/lib/skill-excludes.txt`.

#### Scenario: ECC pi copy dropped
- **WHEN** the repo directory is named `ecc` and contains `pi/core/a/SKILL.md`
- **THEN** that path is not reported

#### Scenario: Other repo unaffected
- **WHEN** a repo not named `ecc` contains `pi/core/a/SKILL.md`
- **THEN** that path is reported

### Requirement: Wiring and catalogue share the rule
`wire.sh` and `catalog.sh` MUST both discover skills only through `find_skill_mds`.

#### Scenario: ECC count
- **WHEN** `repos/ecc` is initialised
- **THEN** `find_skill_mds repos/ecc` reports 293 paths, all under `skills/`

#### Scenario: Catalogue count follows
- **WHEN** a mock repo has one `skills/` skill and one `.kiro` copy
- **THEN** its catalogue section header counts 1
