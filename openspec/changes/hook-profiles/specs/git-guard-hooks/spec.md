## Purpose

Two zero-token PreToolUse guards on Bash that stop an agent from bypassing git's safety nets or committing a secret.

## ADDED Requirements

### Requirement: Block hook bypass and force-push
The `pre-bash-no-bypass` hook SHALL exit 2 with an explanation on stderr when a Bash command runs `git` with `--no-verify`, `git commit` with `-n`, a `core.hooksPath` override, or a force-style `git push`, and exit 2 when `jq` is unavailable.

#### Scenario: No-verify commit blocked
- **WHEN** the command is `git commit -m "x" --no-verify`
- **THEN** the hook exits 2 and the message names `GRID_DISABLED_HOOKS=pre-bash-no-bypass` as the human bypass

#### Scenario: Short no-verify blocked
- **WHEN** the command is `git commit -nm "x"`
- **THEN** the hook exits 2

#### Scenario: Force push blocked
- **WHEN** the command is `git push --force origin next`, `git push -f`, `git push -fu origin next` or `git push origin +next`
- **THEN** the hook exits 2

#### Scenario: Lease push allowed
- **WHEN** the command is `git push --force-with-lease origin next`
- **THEN** the hook exits 0

#### Scenario: Push dry-run flag is not force
- **WHEN** the command is `git push -n origin next`
- **THEN** the hook exits 0

#### Scenario: Quoted mention does not block
- **WHEN** the command is `git commit -m "docs: explain why --no-verify is banned"`
- **THEN** the hook exits 0

#### Scenario: Chained command is inspected
- **WHEN** the command is `git add . && git commit --no-verify -m x`
- **THEN** the hook exits 2

#### Scenario: Unrelated command passes
- **WHEN** the command is `ls -la` or the tool is not Bash
- **THEN** the hook exits 0

#### Scenario: jq missing fails closed
- **WHEN** `jq` is not on PATH and the hook receives any Bash payload
- **THEN** it exits 2 and the message names `jq`

### Requirement: Block commits that add a secret
The `pre-bash-secret-scan` hook SHALL exit 2 when a `git commit` Bash command would commit an added line matching a secret pattern, without printing the matched secret value, and exit 2 when `jq` is unavailable.

#### Scenario: Staged AWS key blocked
- **WHEN** a staged added line contains an AWS access key id and the command is `git commit -m x`
- **THEN** the hook exits 2 and stderr names the file, line number and pattern but not the key text

#### Scenario: Commit with -a scans unstaged tracked changes
- **WHEN** a tracked file has an unstaged added secret and the command is `git commit -am x`
- **THEN** the hook exits 2

#### Scenario: Clean commit passes
- **WHEN** the staged diff contains no pattern match
- **THEN** the hook exits 0

#### Scenario: Pragma allows a known false positive
- **WHEN** the matching added line also contains `grid:allow-secret`
- **THEN** the hook does not block on that line

#### Scenario: Removed secret lines are ignored
- **WHEN** the staged diff only deletes a line that contains a secret pattern
- **THEN** the hook exits 0

#### Scenario: Non-commit commands are skipped fast
- **WHEN** the command is `git status`
- **THEN** the hook exits 0 without running any git diff

#### Scenario: jq missing fails closed
- **WHEN** `jq` is not on PATH and the hook receives any Bash payload
- **THEN** it exits 2 and the message names `jq`
