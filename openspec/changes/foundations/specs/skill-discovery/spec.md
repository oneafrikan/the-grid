## Purpose

Give `wire.sh`, `catalog.sh` and tests one answer to "which SKILL.md files does this repo ship", ignoring translations, per-harness copies and listed paths.

## ADDED Requirements

### Requirement: Discovery excludes translations, dot-dirs and listed prefixes
`find_skill_mds` MUST NOT report a SKILL.md whose repo-relative path starts with `docs/`, `i18n/`, `translations/` or `locales/` followed by a directory matching `^[a-z]{2}([-_][A-Za-z]{2,4})?$`, whose first path component starts with a dot, or that falls under a prefix listed for that repo name in `scripts/lib/skill-excludes.txt`.

#### Scenario: Locale copy dropped
- **WHEN** a repo has `docs/ja-JP/skills/a/SKILL.md` and `skills/a/SKILL.md`
- **THEN** only `skills/a/SKILL.md` is reported

#### Scenario: Non-locale docs dir kept
- **WHEN** a repo has `docs/guides/a/SKILL.md`
- **THEN** it is reported

#### Scenario: Harness copy dropped
- **WHEN** a repo has `.kiro/skills/a/SKILL.md` and `skills/a/SKILL.md`
- **THEN** only `skills/a/SKILL.md` is reported

#### Scenario: Listed prefix dropped for its repo only
- **WHEN** repos named `ecc` and `other` each contain `pi/core/a/SKILL.md`
- **THEN** the path is reported for `other` and not for `ecc`

#### Scenario: Both discovery branches apply the rule
- **WHEN** the fixture is a git checkout, and again when it is a plain directory
- **THEN** the same paths are reported

### Requirement: Wiring and catalogue share the rule
`wire.sh` and `catalog.sh` MUST both discover submodule skills only through `find_skill_mds`.

#### Scenario: ECC count
- **WHEN** `repos/ecc` is initialised at the current pin
- **THEN** `find_skill_mds repos/ecc` reports 293 paths, all under `skills/`

#### Scenario: Catalogue count follows
- **WHEN** a mock repo has one `skills/` skill and one `.kiro` copy
- **THEN** its catalogue section header counts 1
