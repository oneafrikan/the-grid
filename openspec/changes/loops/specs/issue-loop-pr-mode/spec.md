## Purpose

Let an instantiated issue-loop target any base branch and integrate work through
pull requests instead of direct pushes, without leaving files or labels behind.
Use case: unattended overnight builds that land on a long-lived integration
branch for human review.

## ADDED Requirements

### Requirement: Instantiation fills the base branch and mode, creates labels, and is idempotent
`instantiate.sh` SHALL replace every hard-coded `main` with `{{BASE_BRANCH}}` from `--base-branch` (default the repo's `origin/HEAD` branch, else `main`); SHALL keep exactly one of the template's `<!-- MODE:direct -->` / `<!-- MODE:pr -->` blocks, chosen by `--mode` (default `pr` for the `work`, `linux` and `mac-mini` profiles, `direct` for `personal`), leaving no marker; SHALL escape `&`, `|` and `\` in sed-substituted values; SHALL create, only when absent, the opt-in label, `ready-for-human`, `needs-human`, `blocked` and one `role:<name>` label per `--role-labels` entry, listing existing labels with `--limit 200`; and on an identical re-run SHALL write nothing and SHALL never overwrite an existing `loop/loop.conf`. The template's pr block SHALL work in an `issue-<N>` worktree, open a PR to the base whose body contains `Closes #<N>`, relabel to `ready-for-human` and never close the issue; on verify failure the template SHALL discard tracked changes and untracked files before labelling the issue `blocked`.

#### Scenario: Custom base branch is filled everywhere
- **WHEN** `instantiate.sh issue-loop <target> --profile work --base-branch next` runs
- **THEN** the generated `loop/` files contain `next` where the base is needed
- **AND** no generated file contains `origin/main`, `--base main` or `git push origin main`

#### Scenario: Default falls back to main
- **WHEN** the target has no `origin/HEAD` and `--base-branch` is omitted
- **THEN** the base branch is `main`

#### Scenario: PR mode instance never pushes the base branch
- **WHEN** a target is instantiated with `--profile work` and no `--mode`
- **THEN** `loop/loop.conf` contains `MODE=${MODE:-pr}` and the prompt contains `gh pr create` with `--base <base>` and `Closes #`
- **AND** the prompt contains no `git push origin <base>`, no `gh issue close` and no `<!-- MODE` marker

#### Scenario: Direct mode keeps the old flow
- **WHEN** a target is instantiated with `--mode direct`
- **THEN** the prompt contains `git push origin <base>` and `gh issue close` and no `gh pr create`

#### Scenario: Untracked files are removed on verify failure
- **WHEN** the prompt's revert step is executed in a worktree holding a modified tracked file and a new untracked file
- **THEN** `git status --porcelain` is empty afterwards

#### Scenario: Labels created once
- **WHEN** `instantiate.sh` runs with `--role-labels grid-devops,grid-sdet` against a repo whose label list is empty
- **THEN** `gh label create` is called for the four state labels and for `role:grid-devops` and `role:grid-sdet`
- **AND** a second run, with all of them listed, makes no `gh label create` call

#### Scenario: Verify command with ampersands
- **WHEN** `--verify-cmd "make lint && make test"` is passed
- **THEN** the generated files contain the string `make lint && make test`

#### Scenario: Second run changes nothing and tuned caps survive
- **WHEN** `instantiate.sh` runs twice with the same arguments, with `MAX_ISSUES` hand-edited in `loop/loop.conf` between runs
- **THEN** the second run's output lists no `wrote:` lines and the edited value is still present
