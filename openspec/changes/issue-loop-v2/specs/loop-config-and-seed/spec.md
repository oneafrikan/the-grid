## Purpose

One tracked config file drives the loop in any repo, the tool that cuts the pattern into a repo is idempotent and never rewrites tracked hand-edits, and every project the factory seeds starts with the loop OFF and a short list of what to define before turning it on. Use case: cutting the loop into the-grid, a product repo, or a `the-grid-<business>` repo with no the-grid dependency at run time.

## ADDED Requirements

### Requirement: loop.conf is the single source of config
`loop/loop.conf` SHALL be rendered once from `loop.conf.template` by `instantiate.sh` and never overwritten afterwards. Values SHALL be single-quoted so spaces, `&&`, `|` and non-ASCII survive. Each line SHALL have the form `KEY=${KEY:-'value'}` so the environment overrides it. The file SHALL contain no secrets and no machine-specific paths. Keys and defaults:

| Key | Default | Meaning |
|---|---|---|
| `GH_REPO` | detected from `origin` | `owner/name` |
| `BASE_BRANCH` | `origin/HEAD` branch, else `main` | PR target and worktree base |
| `ISSUE_LABEL` | `ready-for-agent` | opt-in label |
| `MODE` | by profile | `pr` or `direct` (direct is interactive only) |
| `VERIFY_CMD` | empty | run by the runner; empty means the runner refuses |
| `VERIFY_TIMEOUT` | `900` | seconds |
| `SETUP_CMD` | empty | run in the worktree before the worker |
| `PROJECT_CONTEXT`, `REVIEW_FOCUS` | prompted | one-liners for prompts and the review hook |
| `WORKER_MODEL` | `sonnet` | always passed |
| `MAX_BUDGET_USD` | `5` | worker `--max-budget-usd`, always passed |
| `ISSUE_TIMEOUT` | `1800` | seconds, worker |
| `WORKER_PERMISSIONS` | `allowlist` | `allowlist` or `bypass` (fallback; see proposal assumption 1) |
| `WORKER_ALLOWED_TOOLS` | read/edit/write/glob/grep and `Bash(git status|diff|log|show|add|commit:*)` | passed as `--allowedTools`; the project appends its test commands |
| `MAX_ISSUES_PER_DAY` | `5` | daily cap |
| `TRUST_GATE` | `on` | `on` or `off` |
| `RUN_ROLE` | `issue-loop` | run-record role when no `agent:` label |

There SHALL be no `MAX_TURNS`, `REVIEW_MODEL`, `LABEL_BUDGETS`, `LOOP_TRUSTED_ACTORS`, `LOOP_OPERATOR_HOME` or `GH_APP_*` key.

#### Scenario: Rendered once
- **WHEN** `instantiate.sh` runs twice and `loop.conf` was hand-edited in between
- **THEN** the second run prints "left alone" for `loop/loop.conf` and the edit survives

#### Scenario: Quoting
- **WHEN** `--verify-cmd 'a && b | c'` and `--project-context "R&D tool (it's ok)"` are given
- **THEN** sourcing `loop.conf` in a subshell yields exactly those strings

#### Scenario: Environment override
- **WHEN** `MAX_BUDGET_USD=1` is exported and the runner starts
- **THEN** the worker argv has `--max-budget-usd 1`

### Requirement: instantiate.sh keeps main's shape and folds in next's good parts
`scripts/instantiate.sh` SHALL be `main`'s version as base (already at `scripts/instantiate.sh` on `main`; `_retired/` is only read), with: options `--repo --project-context --verify-cmd --label --review-focus --base-branch --mode --setup-cmd --worker-model --agent-labels`; base-branch detection from `origin/HEAD`; render-once `loop.conf`; placeholder substitution through awk with values read from the environment (no `sed` delimiter or `&` injection); the shipped `guard-main-push.sh`, `new-agent-worktree.sh`, `post-commit-review.sh`, `run-issue.sh`, `setup.sh`, both prompt templates and `.gitignore` copied verbatim instead of heredocs (`wake.sh` and the cron line are added by B2, see `loop-waker`); label creation (create-if-absent, `--limit 200` on the listing) for `ISSUE_LABEL`, `ready-for-human`, `needs-human`, `blocked`, and `agent:<name>` for each `--agent-labels a,b` entry; and an existing `loop.conf` (or `loop.conf.seed`) read before rendering so flags it does not set are taken from it. It SHALL NOT write launchd or systemd units, SHALL NOT use `bash -l`, SHALL NOT pass `--dangerously-skip-permissions` anywhere (only `run-issue.sh` with `WORKER_PERMISSIONS=bypass`), SHALL NOT write `.claude/settings.json` hook entries, and SHALL never overwrite an existing `CLAUDE.md`.

#### Scenario: Idempotent
- **WHEN** it runs twice with the same arguments into a temp git repo (stub `gh`)
- **THEN** the second run prints no `wrote:` line and the tree is byte-identical

#### Scenario: Prompt template untouched (R10.qa.F5)
- **WHEN** it runs after the pattern's template changed
- **THEN** `loop/loop-prompt.template.md` equals the pattern's file byte for byte, placeholders unfilled

#### Scenario: Profiles
- **WHEN** run with `--profile personal`, `work`, `mac-mini`
- **THEN** `MODE` is `direct`, `pr`, `pr`; for `direct` no guard, worktree helper or runner is copied; `--mode` overrides

#### Scenario: Labels
- **WHEN** run with `--agent-labels grid-backend-dev,grid-devops` against a stub `gh` where only `blocked` exists
- **THEN** `gh label create` is called for the other three standard labels and the two `agent:` labels, and not for `blocked`; a second run creates none

#### Scenario: Default label
- **WHEN** no `--label` is given
- **THEN** `ISSUE_LABEL` is `ready-for-agent`

#### Scenario: Business repo
- **WHEN** the target is any git repo with a GitHub remote and no the-grid checkout exists at `~/.the-grid` or `$GRID_DIR`
- **THEN** instantiation succeeds and the copied hooks pass their decision table using the built-in parser

#### Scenario: .claude ignored
- **WHEN** the target `.gitignore` lacks `.claude/settings.json`
- **THEN** it is appended once

### Requirement: Prompt templates
`loop-prompt.template.md` (interactive `/loop`) SHALL carry `{{BASE_BRANCH}}` and `<!-- MODE:pr -->` / `<!-- MODE:direct -->` blocks; the pr block SHALL contain no `git push origin {{BASE_BRANCH}}`, SHALL push `issue-<N>` only, and its verify-failure path SHALL discard with `git reset --hard HEAD && git clean -fd` (not `git checkout -- .`, which leaves untracked files). `worker-prompt.template.md` (headless) SHALL contain the instructions listed in `loop-runner` "Context given to the worker" and no GitHub write instruction.

#### Scenario: Direct block
- **WHEN** `setup.sh` renders with `MODE=direct`
- **THEN** the output has `git push origin <base>` and no `gh pr create`

#### Scenario: Pr block
- **WHEN** rendered with `MODE=pr`
- **THEN** the output has `gh pr create --base <base>`, `Never push <base>`, and no `git push origin <base>`

#### Scenario: Worker prompt writes nothing remote
- **WHEN** `worker-prompt.template.md` is grepped
- **THEN** it says not to push, open a PR or edit labels, and contains none of the literal commands `gh pr create`, `git push origin`, `--add-label`, `gh issue close`

### Requirement: The project seed replaces the stale stub
`project-factory/templates/_common/prompts/autonomous-coding-loop.template.md` SHALL be removed. In its place `_common/loop/` SHALL ship `loop.conf.seed` (all keys of the table above, `VERIFY_CMD`, `SETUP_CMD`, `BASE_BRANCH` and `MODE=pr` blank or defaulted, each with a one-line comment) and `ENABLE.md` (at most 40 lines): the loop is OFF until the project enables it; what to define first (`VERIFY_CMD`, `BASE_BRANCH`, `MODE` pr by default, `ISSUE_LABEL`, the three caps, a project-specific `SETUP_CMD`); that the loop refuses to run with no `VERIFY_CMD`; that it opens PRs and never merges; and the command `bash <the-grid checkout>/scripts/instantiate.sh issue-loop . --profile work`. The seed SHALL NOT be named `loop.conf` and SHALL NOT make `loop/run-issue.sh` exist. `instantiate.sh` SHALL read `loop/loop.conf.seed`, when `loop/loop.conf` is absent, as the source of defaults.

#### Scenario: Seed lands, loop stays off
- **WHEN** `cut-project.sh python-agents-base <tmp>` runs
- **THEN** `<tmp>/loop/loop.conf.seed` and `<tmp>/loop/ENABLE.md` exist and `<tmp>/loop/run-issue.sh` does not

#### Scenario: Retrofit never clobbers
- **WHEN** the target already has a different `loop/loop.conf.seed`
- **THEN** it is skipped and listed in the "skipped" report

#### Scenario: Old stub gone
- **WHEN** the repo is grepped for `autonomous-coding-loop`
- **THEN** there are no matches outside `openspec/changes/` and the migration notes

#### Scenario: Seed feeds instantiate
- **WHEN** the seed sets `VERIFY_CMD='pytest'` and `instantiate.sh` runs with no `--verify-cmd`
- **THEN** the rendered `loop.conf` has `VERIFY_CMD='pytest'`

### Requirement: Template docs point at the new seed
The seven files that mention `autonomous-coding-loop` (checked by grep: `project-factory/README.md` and the six template docs below) SHALL be rewritten, and the `cut-project.sh` header comment (which says "the issue-loop pairing prompt" without that filename) SHALL be updated. The references SHALL say "set `VERIFY_CMD` (and `SETUP_CMD`) in `loop/loop.conf`, seeded from `loop/loop.conf.seed`; see `loop/ENABLE.md`", keeping each template's own verify command. They are `lamp-agents-base/README.md:39` and `CLAUDE.md:31` (its pre-flight `bash scripts/worktree-setup.sh` becomes `SETUP_CMD`), `python-agents-base/CLAUDE.md:17`, `python-astro-content-agent/CLAUDE.md:15`, `finance-agents-base/README.md:60` and `CLAUDE.md:30` (keep the note that the loop maintains this codebase, separate from the watcher's own heartbeat), `project-factory/README.md:38`. No template doc SHALL claim every project grinds its backlog unattended.

#### Scenario: No stale references
- **WHEN** the seven files are grepped for `autonomous-coding-loop` and `{{VERIFY_CMD}}`
- **THEN** no matches

#### Scenario: Verify command kept
- **WHEN** `python-agents-base/CLAUDE.md` is read
- **THEN** it still shows `pytest` as the `VERIFY_CMD` value

#### Scenario: Opt-in stated
- **WHEN** `project-factory/README.md` and `_common/loop/ENABLE.md` are read
- **THEN** both say the loop is opt-in and refuses to run without `VERIFY_CMD`
