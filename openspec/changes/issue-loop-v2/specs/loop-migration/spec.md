## Purpose

Move the repo from "two loops, one quarantined, docs say it is dead" to one loop and docs that match it. Line numbers below are as of `next` @ 05b23d4 and are search anchors, not promises: re-find each by content when building (after `next` is merged into `main` they may shift). Built after `next` is merged into `main`, by worktree agents and operator-merged PRs; the loop does not exist yet and cannot build this.

## ADDED Requirements

### Requirement: What is restored
The change SHALL restore `automation-factory/docs/gh-triage-to-issue-loop.md` as a generic rewrite, at most 80 lines, keeping only: the join between triage and execution is the `ready-for-agent` label; the Agent Brief (a comment headed `## Agent Brief`) is the handoff; the loop never classifies; the severity gate (critical or high is `ready-for-human`) is gh-triage's; the label schema table; a pointer to the pattern README. It SHALL NOT contain any account or organisation name, repo name from another project, chat channel id, server path, cron job id or `LOGS/` reference that the `main` copy holds. The original stays in the private archive.

#### Scenario: Personal-data gate
- **WHEN** `bash scripts/check-personal.sh automation-factory/docs/gh-triage-to-issue-loop.md` runs with the private denylist present (`GRID_REQUIRE_DENYLIST=1`)
- **THEN** exit 0, and the file contains no chat-channel name or id (no `#name` channel reference, no `C[0-9A-Z]{9,}` id), no absolute server path (`/srv/`, `/home/`, `/Users/`), no scheduler job id or registry file name, no `LOGS/` reference, and no host, account or repo name belonging to another project

#### Scenario: Depersonalise test follows
- **WHEN** `tests/test_depersonalise.bats` runs
- **THEN** `automation-factory/docs/gh-triage-to-issue-loop.md` (lines 15 and 28) is no longer in `REMOVED_PATHS` / `REMOVED_NAMES`, and the other removed paths are still asserted absent

#### Scenario: Brief and doc agree
- **WHEN** the doc is read
- **THEN** it says the loop reads the Agent Brief and does not classify, matching `agent-factory/roles/gh-triage/SKILL.md`

### Requirement: What is kept as is
`scripts/lib/render-schedule.sh` (extended only by `every:N`), `scripts/run-record.sh`, `hooks/lib/common.sh`, `scripts/usage/install-schedule.sh`, `scripts/instincts.sh` and `scripts/grid` SHALL keep working unchanged in behaviour.

#### Scenario: Other schedulers unaffected
- **WHEN** `tests/test_render_schedule.bats`, `tests/test_usage_schedule.bats` and `tests/test_instincts_schedule.bats` run
- **THEN** they pass without edits to their expectations

### Requirement: What is dropped
The following SHALL be removed (each by `git rm`, in the PR for group 7): `automation-factory/patterns/issue-loop/run-issues.sh`; `automation-factory/docs/secure-agent-loop.md`; `tests/test_docs_loop_secrets.bats`; `_retired/` in full (see the precondition below); the loop-specific parts of `docs/uplift-runbook.md` (Sections 1 to 3, lines 1-359; the `loops, group 5` block under Section 4, lines 360-393 less the Section 4 heading and intro; Section 5, lines 765-824), keeping the non-loop HUMAN groups from `### depersonalise, group 1` (about line 394) to the end of Section 4 and re-titling the file; the minter stub in `tests/helpers/stubs.bash` (the `GRID_APP_TOKEN_BIN` block near line 425 and the `curl` App-installation stubs and their header lines 89-92 and 106-109); preflight checks 2b, 2d-2f and 2i of the old runner, the `linux` instantiate profile's user assumptions, `LOOP_OPERATOR_HOME`, `LOOP_TRUSTED_ACTORS`, `GH_APP_*`, `gh-app-token.sh`.

#### Scenario: Nothing left of the old design
- **WHEN** the paths `automation-factory`, `scripts`, `tests`, `docs`, `project-factory`, `hooks`, `README.md`, `USAGE.md`, `CLAUDE.md`, `index.html` (never `_retired/`, `openspec/`, `agent-factory/roles`, `dist/`, `plugins/`) are grepped for `LOOP_OPERATOR_HOME`, `GH_APP_ID`, `gh-app-token`, `run-issues.sh`, `secure-agent-loop`, `RETIRED.md`, `_retired/issue-loop`
- **THEN** no matches

#### Scenario: Non-loop runbook content survives
- **WHEN** `docs/uplift-runbook.md` is read
- **THEN** every `### <change>, group N` heading from `depersonalise, group 1` onward is still present, and no heading or step mentions a loop user or a GitHub App (B1: the usage-schedule step 8.3 keeps its `enable-linger` line, which is about the weekly usage job and not the loop)

#### Scenario: Shared stubs still serve other tests
- **WHEN** `tests/test_auto_handoff.bats`, `test_grid_drift.bats`, `test_instincts_analyse.bats`, `test_instincts_eval.bats`, `test_instincts_schedule.bats`, `test_stubs.bats` run
- **THEN** they pass (they load `helpers/stubs` for `claude`, `gh`, `loginctl`, `launchctl`, `crontab`)

### Requirement: `_retired/` is removed only after the operator confirms the GitHub-side cleanup
Group 7 SHALL NOT delete `_retired/` until the operator states in the PR that the "GitHub-side cleanup" steps of `_retired/issue-loop/RETIRED.md` (delete the loop's GitHub App and its keys; replace, not delete, the `next-needs-pr` ruleset once branch protection exists; delete the sandbox repo; remove loop hook entries and scheduler entries from each machine) are done or have been copied to a private note. Whether they are done is UNVERIFIED.

#### Scenario: Gate on confirmation
- **WHEN** the PR for group 7 is opened without that confirmation
- **THEN** the `_retired/` deletion is left out of the PR and listed as pending

### Requirement: What is rewritten
These SHALL be rewritten to describe the v2 loop and to carry no claim that the loop is retired, quarantined or abandoned: `automation-factory/patterns/issue-loop/README.md` (status note at lines 3-8 removed; sections: what it is, instantiate, `loop.conf` table, the runner, the waker, hooks and known gaps, role routing, "what the worker can and cannot do" stating plainly that it has the operator's `gh` login and the guard is a mistake-catcher); `automation-factory/README.md` lines 50-63 (roadmap bullet for `instantiate.sh` and the `docs/secure-agent-loop.md` pointer); `loop-prompt.template.md`; `setup.sh`; `loop.conf.template`.

#### Scenario: No retirement language
- **WHEN** `automation-factory/` is grepped case-insensitively for `retired`, `quarantin`, `abandoned` (this path holds no role archive, so no exclusion is needed)
- **THEN** no matches

#### Scenario: README documents the stages
- **WHEN** the pattern README is read
- **THEN** it states that the first run is started by hand (`bash loop/run-issue.sh`), that the waker is installed by the operator, and which of backoff and stale-lock handling exist

### Requirement: Merge-fallout edits
Every file that assumes the loop's retirement SHALL be edited so it describes v2 or drops the claim. Each has a test or grep that fails if the old text returns.

| File and anchor | Edit |
|---|---|
| `tests/test_docs_factories.bats` lines 20-109: the comment block and eight tests ("retired loop: ..." at lines 26, 33, 42, 71, 90, 98; "retired loop docs carry the banner" at 51; "the generic secure-loop playbook carries a neutral status note" at 59) | delete the quarantine, banner, RETIRED.md and playbook tests; keep and rewrite the factory-pattern test (42; its `run-issues.sh` check at line 44 becomes `run-issue.sh`) to assert `run-issue.sh`, `wake.sh` and `README.md` exist; add the "no retirement language" grep. Tests from line 110 (`openspec@latest` pin) and 129 (factory count) are unrelated and stay |
| `tests/test_gate.bats:411-419` ("the quarantined issue-loop is excluded from lint") | delete the test; add one asserting the pattern's `run-issue.sh`, `wake.sh` and `hooks/*.sh` reach shellcheck |
| `scripts/gate.sh:7-8` and `:108` (comments "_retired/ is archived and never linted", "_retired/ is deliberately not listed") | delete the comments; globs at 111 stay |
| `scripts/stage-site.sh:74` | comment names `_retired` as an example of a tracked `_dir`; change the example (UNVERIFIED that no other `_`-prefixed tracked dir exists; check `git ls-files` first) |
| `CLAUDE.md:96` (the "RETIRED, do not deploy" bullet) and `CLAUDE.md:90` ("the retired issue-loop set it in its `VERIFY_CMD`") | replace with a Key-files bullet for the live pattern, `scripts/instantiate.sh`, `loop.conf`; reword line 90 |
| `README.md:98` (factories table row), `:237` (tree line `_retired/`), `:251` (tree line `instantiate.sh ← RETIRED`) | drop the retirement text; remove the `_retired/` tree line; describe `instantiate.sh` as live |
| `USAGE.md:123-125` | restore the one-command cut; link the pattern README |
| `index.html:981` and `:1788` | same edits as README rows; mirrored text must stay in step (`docs/architecture.md` "Hand-synced copies" if `front-door` has landed) |
| `automation-factory/README.md:50-63` | per "What is rewritten" |
| `tests/helpers/stubs.bash:425` | minter stub removed per "What is dropped" |
| `docs/uplift-runbook.md` | per "What is dropped" |
| `tests/test_depersonalise.bats:15,28` | per "What is restored" |
| `tests/test_render_schedule.bats` | added in B1: the example script name `run-issues.sh` is replaced by a neutral one (inputs and expected output renamed together), because the old-design grep covers `tests/` |
| `openspec/changes/loops/` | add `SUPERSEDED.md` pointing at `issue-loop-v2`; do not archive `loops` (its `issue-loop-*` specs would conflict); its unbuilt Phase B (`karpathy-loop`, `cli-agent-cron`, tasks 6-8) is deferred, recorded in `TODO.md`, not deleted |
| `automation-factory/patterns/issue-loop/.gitignore` | keeps `loop-prompt.md` |

#### Scenario: Fallout grep
- **WHEN** the same path list as "Nothing left of the old design" is grepped case-insensitively for `retired.*loop|loop.*retired|quarantined.*loop|RETIRED - do not deploy`
- **THEN** no matches. The bare words "do not deploy" and `retired` are NOT searched: `agent-factory/roles/devops/SKILL.md`, `agent-factory/roles/seo/SKILL.md`, `dist/personas` and `plugins/` copies legitimately contain them. Because `_retired/` is outside the path list, these greps pass whether or not group 7 has deleted it (task 7.0 may leave it)

#### Scenario: Gate green after the edits
- **WHEN** `bash scripts/gate.sh` runs on the PR branch
- **THEN** it passes, including `tests/test_docs_factories.bats` and `tests/test_gate.bats`

### Requirement: Supersession of `loops`
`openspec/changes/loops/` SHALL be marked superseded by `issue-loop-v2` without deleting any file. Its unchecked proof tasks (5.1a to 5.8) SHALL be replaced in effect by the proof tasks of this change; the `karpathy-loop` and `cli-agent-cron` specs SHALL be recorded as deferred with the reason (the loop that was to build them is rebuilt first).

#### Scenario: Marker present
- **WHEN** `openspec/changes/loops/SUPERSEDED.md` is read
- **THEN** it names `issue-loop-v2`, lists the deferred capabilities, and says not to archive `loops`

#### Scenario: Nothing deleted
- **WHEN** `git diff --stat` is taken for the supersession PR
- **THEN** it shows only an added file under `openspec/changes/loops/` plus the `TODO.md` line

### Requirement: The-grid's own instance is cut after B1, not by it
Cutting the loop into the-grid (`bash scripts/instantiate.sh issue-loop . --profile work --base-branch next --verify-cmd "GRID_REQUIRE_DENYLIST=1 bash scripts/gate.sh"`) is a separate operator step after B1 is merged and proven. No B1 task SHALL assume `loop/` exists in the-grid.

#### Scenario: B1 builds on a clean `main`
- **WHEN** B1 groups are built on a checkout with no `loop/` directory
- **THEN** every group's acceptance test passes using temp repos only

### Requirement: New tracked scripts and paths are added to docs/architecture.md
Once `front-door` has landed `docs/architecture.md`, every group of this change that adds a tracked file under `scripts/` or `docs/`, or a top-level path, SHALL add it to that file's tree and docs index in the same PR (front-door `tests/test_front_door.bats` case 2.6 fails the gate otherwise). In this change that is `scripts/instantiate.sh` (group 4) and, for the restored doc, a link from `README.md` or `docs/architecture.md` if it sits under `docs/`. UNVERIFIED: `docs/architecture.md` does not exist on `next` today; if `front-door` has not landed, the groups skip this and the PR says so.

#### Scenario: Drift guard passes
- **WHEN** `front-door` is merged and group 4's PR runs `bash scripts/gate.sh`
- **THEN** `scripts/instantiate.sh` appears by name in `docs/architecture.md` and the gate passes

#### Scenario: Not yet landed
- **WHEN** `docs/architecture.md` does not exist
- **THEN** no group creates it; the PR description records "architecture.md not present: skipped"
