## Purpose

Keep canonical knowledge changes behind a human: reviewed in a PR, never merged under the standing merge-on-green approval.

## ADDED Requirements

### Requirement: Current protection is verified, not assumed
Before any protection change, the implementer SHALL record the state of CODEOWNERS, classic branch protection and rulesets for `next` and `main` (command and output) in the PR description.

#### Scenario: Record matches reality
- **WHEN** task 4.1 runs `gh api repos/<owner>/<repo>/rulesets` and the branch-protection endpoints
- **THEN** the PR description quotes each result, including any 404

### Requirement: CODEOWNERS covers canon
`.github/CODEOWNERS` SHALL assign `knowledge/canon/` to the operator's GitHub handle, with a comment saying why; it SHALL NOT assign other paths in this change.

#### Scenario: Entry present
- **WHEN** `.github/CODEOWNERS` is read
- **THEN** it has a `knowledge/canon/` line with an owner and no other path line

#### Scenario: Canon PR requests the owner
- **WHEN** a PR touches `knowledge/canon/x.md`
- **THEN** GitHub lists the owner as a requested reviewer (checked by hand on the first canon PR; UNVERIFIED until then)

### Requirement: Canon is excluded from merge-on-green
The `knowledge-store` spec (A2) states this exclusion, but no session reads specs. `CLAUDE.md` SHALL contain an imperative block stating that a PR changing any path under `knowledge/canon/` is never merged under the standing approval to merge on green CI plus independent QA, and that a human merges it. `.github/pull_request_template.md` SHALL carry a checkbox with the command `git diff --name-only origin/next...HEAD -- knowledge/canon` and the instruction that non-empty output means a human merges.

#### Scenario: Block present
- **WHEN** `CLAUDE.md` is read
- **THEN** it names `knowledge/canon/`, "never merged", and "human"

#### Scenario: Template checkbox
- **WHEN** the PR template is read
- **THEN** it contains the exact diff command above

#### Scenario: Canon file changed
- **WHEN** a branch modifies `knowledge/canon/x.md` and the command is run against `origin/next`
- **THEN** it prints `knowledge/canon/x.md`

### Requirement: Canon proposals are never agent-pickable
A canon-proposal issue SHALL carry `knowledge` and `ready-for-human` and SHALL NOT carry `ready-for-agent`.

#### Scenario: Labels
- **WHEN** the sweep escalates a `canonical` claim (A2) in a test repo
- **THEN** the issue has `knowledge` and `ready-for-human` and lacks `ready-for-agent`

### Requirement: No automatic write path into canon on a direct branch
The sweep's direct-commit path (`knowledge.py apply` without `--proposal-for`) SHALL have no code that writes under `knowledge/canon/`. This holds even though the `next` ruleset lets the operator's login bypass the PR rule, so the PR rule alone would not stop a direct canon write.

#### Scenario: Canonical claim, direct apply
- **WHEN** `knowledge.py apply` runs on a plan containing a `canonical` claim, without `--proposal-for`
- **THEN** `knowledge/canon/` is unchanged and the claim is reported as escalated

#### Scenario: Static check
- **WHEN** `scripts/knowledge.py` is searched for a write to a `canon` path
- **THEN** every match is inside the `--proposal-for` branch of the code

### Requirement: No ruleset change
This change SHALL NOT edit any repository ruleset or branch protection (operator decision). The protection against a direct canon write is the no-write-path requirement above.

#### Scenario: No settings change
- **WHEN** the PR for this change is reviewed
- **THEN** it contains no `gh api` call that writes a ruleset or branch protection
