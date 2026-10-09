## Purpose

Let an instantiated issue-loop target any base branch and integrate work through
pull requests instead of direct pushes, without leaving files or labels behind.
Use case: unattended overnight builds that land on a long-lived integration
branch for human review.

## ADDED Requirements

### Requirement: Base branch is a placeholder
The issue-loop template and `instantiate.sh` SHALL use a `{{BASE_BRANCH}}` value, set by `--base-branch` (default the repo's `origin/HEAD` branch, else `main`), in place of every hard-coded `main`.

#### Scenario: Custom base branch is filled everywhere
- **WHEN** `instantiate.sh issue-loop <target> --profile work --base-branch next` runs
- **THEN** the generated `loop/` files contain `next` where the base is needed
- **AND** no generated file contains `origin/main`, `--base main` or `git push origin main`

#### Scenario: Default falls back to main
- **WHEN** the target has no `origin/HEAD` and `--base-branch` is omitted
- **THEN** the base branch is `main`

### Requirement: PR integration mode
In `pr` mode the loop prompt SHALL work each issue in a worktree on branch `issue-<N>` cut from `origin/<base>`, push that branch, open a PR to `<base>` whose body contains `Closes #<N>`, relabel the issue from the opt-in label to `ready-for-human`, and leave the issue open.

#### Scenario: PR mode instance never pushes the base branch
- **WHEN** a target is instantiated with `--mode pr`
- **THEN** `loop/loop-prompt.template.md` contains `gh pr create` with `--base <base>` and `Closes #`
- **AND** it contains no `git push origin <base>` line and no `gh issue close`

#### Scenario: Direct mode keeps the old flow
- **WHEN** a target is instantiated with `--mode direct`
- **THEN** the prompt contains `git push origin <base>` and `gh issue close`
- **AND** it contains no `gh pr create`

#### Scenario: Mode markers do not leak
- **WHEN** any instance is generated
- **THEN** the generated prompt contains no `<!-- MODE` marker

### Requirement: Profile default modes
`instantiate.sh` SHALL default `--mode` to `pr` for the `work` and `linux` profiles and to `direct` for `personal` and `mac-mini`, and SHALL let `--mode` override it.

#### Scenario: Work profile defaults to PR
- **WHEN** `instantiate.sh` runs with `--profile work` and no `--mode`
- **THEN** `loop/loop.conf` contains `MODE=${MODE:-pr}`

### Requirement: Verify failure leaves a clean tree
On verify failure the loop prompt SHALL discard tracked changes and untracked files created by the agent before labelling the issue `blocked`.

#### Scenario: Untracked files are removed
- **WHEN** the prompt's revert step is executed in a worktree holding a modified tracked file and a new untracked file
- **THEN** `git status --porcelain` is empty afterwards

### Requirement: All escape and state labels exist
`instantiate.sh` SHALL create the opt-in label, `ready-for-human`, `needs-human`, `blocked` and one `role:<name>` label per name given in `--role-labels` in the target repo when they are absent, listing existing labels with a limit high enough to see all of them, and SHALL NOT modify labels that already exist.

#### Scenario: Four labels created on a fresh repo
- **WHEN** `instantiate.sh` runs against a repo whose label list is empty
- **THEN** exactly four `gh label create` calls are made, for the four names above

#### Scenario: Role labels created on request
- **WHEN** `instantiate.sh` runs with `--role-labels grid-devops,grid-sdet` against a repo whose label list is empty
- **THEN** `gh label create` is called for `role:grid-devops` and `role:grid-sdet` in addition to the four state labels

#### Scenario: Re-run is a no-op
- **WHEN** `instantiate.sh` runs again and all requested labels are listed
- **THEN** no `gh label create` call is made

### Requirement: Placeholder values are escaped
`instantiate.sh` SHALL escape `&`, `|` and `\` in values substituted by sed so that values such as `a && b` appear verbatim in the generated files.

#### Scenario: Verify command with ampersands
- **WHEN** `--verify-cmd "make lint && make test"` is passed
- **THEN** the generated prompt contains the string `make lint && make test`

### Requirement: Instantiation is idempotent
Re-running `instantiate.sh` with identical arguments SHALL report every file as unchanged and SHALL NOT overwrite an existing `loop/loop.conf`.

#### Scenario: Second run changes nothing
- **WHEN** `instantiate.sh` runs twice with the same arguments
- **THEN** the second run's output lists no `wrote:` lines
- **AND** `git status --porcelain` in the target is identical after both runs

#### Scenario: Tuned caps survive a re-run
- **WHEN** `loop/loop.conf` has `MAX_ISSUES` edited and `instantiate.sh` runs again
- **THEN** the edited value is still present
