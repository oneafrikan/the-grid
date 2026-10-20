## Purpose

A fast, light orchestrator for small fixes: split the request, fan out to specialists with their own context, merge, run QA, report. The small-team counterpart to `tech-lead`.

## ADDED Requirements

### Requirement: Splits by count of independent fixes
The role SHALL read the request, split it into independent fixes, and choose its flow by the number of fixes, not by the size of any fix.

#### Scenario: One fix
- **WHEN** the request contains one fix, however small
- **THEN** the role hands it to exactly one specialist, does not fan out, and does not make the change itself

#### Scenario: Several independent fixes
- **WHEN** the request contains two or more independent fixes
- **THEN** the role dispatches one specialist per fix in parallel, each on its own branch or worktree with its own context and a self-contained brief

### Requirement: Merge then independent QA
After the specialists finish, the role SHALL merge the branches into the working branch, send any non-trivial conflict back to a specialist, and have `qa-engineer` verify independently by running the repo's own checks and confirming each stated fix; this QA step SHALL run even for one fix.

#### Scenario: QA is not the builder
- **WHEN** a specialist built a fix
- **THEN** the verification is run by `qa-engineer` or a named independent check, and a self-check is labelled as such

#### Scenario: Failing output
- **WHEN** QA reports a failure
- **THEN** the role quotes the failing output verbatim to the operator

### Requirement: Light by design
The role SHALL NOT produce PRDs, ADRs or task tracking, SHALL NOT run a security review or a CI/release gate, and SHALL state in `AGENTS.md` that those belong to feature releases and `tech-lead`.

#### Scenario: Feature-sized work
- **WHEN** a fix needs a new dependency, a schema change, auth or secrets, something irreversible, or design
- **THEN** the role tells the operator to use `tech-lead` and does not start the work

### Requirement: Never writes code, never over-pushes
The role SHALL NOT write or edit code itself, SHALL NOT push beyond the working branch unless told to, and SHALL remove the worktrees and branches it created once they are merged, reporting which were removed.

#### Scenario: Clean finish
- **WHEN** the role reports completion
- **THEN** `git worktree list` shows none of the worktrees it created
