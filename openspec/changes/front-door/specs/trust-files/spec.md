## Purpose

Give outsiders the standard trust and contribution files so they know how to report problems and what to expect.

## ADDED Requirements

### Requirement: Security policy
The repository SHALL include SECURITY.md that states scope, how to report privately, the acknowledgement target, and supported versions.

#### Scenario: Reporting path
- **WHEN** SECURITY.md is read
- **THEN** it links GitHub private vulnerability reporting for this repo and states supported versions
- **AND** it contains no email address

### Requirement: Contribution guide
The repository SHALL include CONTRIBUTING.md that states the branch to target, the gate command, the rules that every new asset names its use case, carries no sponsored content and no personal data, and that issues are the only discussion channel.

#### Scenario: Rules present
- **WHEN** CONTRIBUTING.md is read
- **THEN** it names `next` as the PR target, `bash scripts/gate.sh` as the check, and the three content rules

### Requirement: Changelog
The repository SHALL include CHANGELOG.md in Keep a Changelog form with an Unreleased section.

#### Scenario: Unreleased heading
- **WHEN** CHANGELOG.md is read
- **THEN** it contains `## [Unreleased]`

### Requirement: Stale prompt retired
The LAMP build prompt SHALL live under `prompts/_retired/` with a header recording that it is superseded and listing its known gaps, and nothing SHALL link to its old path.

#### Scenario: Moved
- **WHEN** the repo is scanned
- **THEN** `prompts/2026-06-13-openclaw-lamp-team-prompt.md` does not exist and the retired copy begins with a superseded notice
