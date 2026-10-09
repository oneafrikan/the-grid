## Purpose

Offer the README in nine languages without letting translations silently go stale or costing tokens unless asked.

## ADDED Requirements

### Requirement: README-only, nine locales
The repository SHALL provide machine translations of README.md only, as `README.<locale>.md` for zh-CN, ja, es, pt-BR, de, fr, it, ko and ru, and no other document SHALL be translated.

#### Scenario: Locale files
- **WHEN** `translate-readme.sh --all` completes
- **THEN** nine README.<locale>.md files exist
- **AND** no other translated file is created

### Requirement: Machine-translated marking and source hash
Each translation SHALL begin with an HTML comment recording the source README sha256, the locale and the words "machine-translated", followed by a visible notice that English is authoritative.

#### Scenario: Header
- **WHEN** a translation is generated
- **THEN** its first line matches `<!-- machine-translated from README.md; source-sha256=<64 hex>; locale=<locale>; ... -->`
- **AND** a blockquote notice links to README.md

### Requirement: Language switcher
README.md and every translation SHALL carry a language switcher between `<!-- langs -->` markers that lists English and each existing translation, and SHALL NOT link to a translation file that does not exist.

#### Scenario: Only existing files
- **WHEN** only README.ja.md exists
- **THEN** the switcher in README.md links English and Japanese only

### Requirement: Staleness detection by source hash
scripts/check-translations.sh SHALL compare each translation's recorded hash with the hash of the current README.md after removing the switcher block and count-marker values, and SHALL exit non-zero listing stale locales.

#### Scenario: Prose edit
- **WHEN** a sentence in README.md changes
- **THEN** check-translations.sh prints STALE for each existing locale and exits 1

#### Scenario: Count or switcher change
- **WHEN** only a count marker value or the switcher block changes
- **THEN** check-translations.sh reports no stale locales

#### Scenario: Strict mode
- **WHEN** a locale file is missing and `--strict` is passed
- **THEN** the check exits 1

### Requirement: Opt-in, budgeted generation
Translation SHALL run only when `translate-readme.sh` is invoked explicitly, SHALL make one model call per locale, and SHALL NOT run from the gate, hooks or CI.

#### Scenario: Gate does not translate
- **WHEN** `gate.sh` runs with a stale translation
- **THEN** it prints a WARN and makes no model call and does not fail

#### Scenario: Dry run
- **WHEN** `translate-readme.sh --dry-run --all` runs
- **THEN** no model command is invoked

### Requirement: Validated atomic output
translate-readme.sh SHALL reject model output that changes the number of code fences, drops a count marker or a relative link target, or does not start at the top heading, and SHALL leave any existing file untouched.

#### Scenario: Broken output
- **WHEN** the stub model returns text with a missing code fence
- **THEN** the script exits 1 and the previous translation file is unchanged
