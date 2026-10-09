# Tasks

Default verify command: `bash scripts/gate.sh`. All tests are bats under `tests/`, start with `common_setup` from `tests/helpers/setup.bash`, and use temp dirs plus the `GRID_DIR`, `GRID_BASELINE`, `SKILLS_DIR`, `AGENTS_DIR`, `GRID_HOST` overrides; none may read the real `~/.claude`, `~/.claude/projects`, `~/.grid` or `~/.the-grid-private`. Python is 3 stdlib only. New shell scripts must be shellcheck-clean (`shellcheck -S warning`). Comment code generously. No personal data (names, emails, hostnames, absolute home paths) in any tracked file, fixtures included. Design details and schemas are in `design.md`; do not re-decide anything under `## Decisions`. Per the merge order, this change lands after `vetting`; rebase on `next` before opening each PR (both edit `scripts/gate.sh`).

## 1. Budget measurement and gate check

Depends on: foundations#2 (CI runs on `next`; `GRID_BASELINE` in `wire.sh`), foundations#1 (discovery exclusions).

Files: `scripts/budget.py` (new), `scripts/lib/baseline_wired.py` (new), `docs/budget-target.json` (new), `scripts/gate.sh`, `tests/test_budget.bats` (new), `CLAUDE.md` (Key files).

- [ ] 1.1 Write `scripts/lib/baseline_wired.py`: `baseline_wired(grid_dir) -> list[dict] | None` with keys `name`, `source_dir`, `repo` (`repos/<repo>` dir name, or `owned` for root `skills/`). It runs `bash <grid_dir>/scripts/wire.sh` into a temp `SKILLS_DIR`/`AGENTS_DIR` with `GRID_SKIP_CATALOG=1`, `GRID_HOST=__baseline__` and `GRID_DIR=<grid_dir>` (passing `GRID_BASELINE` through when set), then reads the symlinks in the temp `SKILLS_DIR`; links whose target is under `agent-factory/projects/` are ignored. Returns `None` when the baseline file (`GRID_BASELINE` else `<grid_dir>/baseline-submodules.txt`) is absent or `git -C <grid_dir> submodule status` shows a line starting `-`.
- [ ] 1.2 Write `scripts/budget.py` per `design.md` section 1: the stdlib frontmatter scalar reader (plain, single-quoted, double-quoted, `>`, `>-`, `|`; whitespace collapsed), the entry cost model including `when_to_use` and `disable-model-invocation: true`, the `owned` and `baseline` scopes, `--report`, `--check`, `--update-target`, `--allow-raise`, `--json`, exit 3 when only the baseline scope is skipped. Roles come from `agent-factory/roles/*/role.yaml` (skip `_retired`), using `description` if present else `"<title>. <summary>"`. Honour `GRID_DIR`. `--check` failures print the offending file path.
- [ ] 1.3 Create `docs/budget-target.json` with the schema in `design.md`, filled by `python3 scripts/budget.py --update-target --allow-raise` on the current tree so the gate passes at this commit. Set `per_entry_max_chars` to the current longest owned entry and `skill_body_max_bytes` to the current largest owned `SKILL.md` for now; groups 3 and 4 lower them to 250 and 4000.
- [ ] 1.4 In `scripts/gate.sh` add `run_budget_check` and `check budget run_budget_check` (after `catalog`): runs `python3 scripts/budget.py --check`; exit 3 appends `budget-baseline` to `SKIPPED` and returns 0. Add `budget` to the header comment list of checks.
- [ ] 1.5 Add `tests/test_budget.bats`, building a mock grid in a temp dir with `make_skill` and `printf` (no committed fixture tree needed): (a) totals match hand-counted descriptions including a folded `>` scalar, a `when_to_use` field, a `disable-model-invocation: true` skill counted as name only, and a 2,000-char description cut at 1,536; (b) `--check` passes at the target and fails when a description grows by 1 char; (c) an owned entry over `per_entry_max_chars` fails `--check` and names the file; (d) `--update-target` lowers a number and refuses to raise one without `--allow-raise`; (e) baseline scope exits 3 when the baseline file is absent and is measured when a baseline file plus `repos/x/skills/y/SKILL.md` exist (point `GRID_BASELINE` at the temp file); (f) with `GRID_HOST=testhost` exported, adding `machines/testhost.txt` that subtracts a baseline skill leaves the baseline number unchanged; (g) a role dir under `roles/_retired/` is not counted; (h) running twice gives identical `--json`.
- [ ] 1.6 Add one line for `scripts/budget.py` and `docs/budget-target.json` to `CLAUDE.md` Key files, including "lowering a number is normal; raising one needs `--allow-raise` and review".

Acceptance: `tests/lib/bats-core/bin/bats tests/test_budget.bats` green; `python3 scripts/budget.py --check` exits 0 or 3 on this repo; `bash scripts/gate.sh` shows a `budget` check PASS.
Verify: `bash scripts/gate.sh`.

## 2. One-line role descriptions

Depends on: 1.

Files: `agent-factory/compose.py`, `agent-factory/roles/*/role.yaml` (38), `agent-factory/docs/role-authoring.md`, `docs/budget-target.json`, `tests/test_role_description.bats` (new).

- [ ] 2.1 In `agent-factory/compose.py` add `description` to `ROLE_YAML_KEYS`; in `emit_cc_subagent` and `emit_cc_skill` set the frontmatter `description` to `" ".join(role_meta(role)["description"].split())` when present, else keep the existing f-strings unchanged. `deploy.py` calls these functions, so it inherits the change; do not edit `deploy.py`.
- [ ] 2.2 Add `description:` to every `agent-factory/roles/*/role.yaml` (not `_retired`): one line, <= 250 chars, form `<Title>. <what it owns>. Use for <when to reach for it>.`, facts from the existing `summary:` only (do not invent capabilities), no "Use this subagent" or "Invoke with" text. Keep `summary:` unchanged (rosters use it).
- [ ] 2.3 Add a "Description" paragraph to `agent-factory/docs/role-authoring.md`: required for new roles, one line, <= 250 chars, keeps when-to-use phrasing, why (listing budget).
- [ ] 2.4 Tests in `tests/test_role_description.bats` (copy the venv-skip and `GRID_PRIVATE_ROLES_DIR` setup from `tests/test_compose_lint.bats`; temp roles plus a minimal temp compose config): (a) a specialist with `description:` composes to a subagent whose frontmatter description equals it exactly and contains no `Use this subagent`; (b) an orchestrator composes to a skill with the same property and no `Invoke with`; (c) a role without `description:` composes to `<Title>. <summary> Use this subagent for <role> work.` exactly; (d) `compose.py --lint-roles` accepts the new key on every real role and still rejects a misspelt key (`descripton:`) in a temp role.
- [ ] 2.5 Run `python3 scripts/budget.py --update-target`; commit the lowered `docs/budget-target.json`.
- [ ] 2.6 If `agent-factory/projects/<cfg>` exists in the working tree for `core`, `grid` or `finance-desk`, recompose that cfg (`agent-factory/.venv/bin/python agent-factory/compose.py agent-factory/examples/<cfg>.yaml --target claude-code`) so the gate's compose check passes. Never compose any other config and never run `wire.sh`. State in the PR body that other machines must recompose after pulling.

Acceptance: new tests green; every public `role.yaml` has a single-line `description` <= 250 chars (`python3 scripts/budget.py --check` enforces it); orchestrator and agent role totals lower than group 1's.
Verify: `bash scripts/gate.sh`.

## 3. Owned skill descriptions <= 250 chars with triggers kept

Depends on: 1.

Files: `skills/*/SKILL.md` (frontmatter `description:` only), `docs/budget-target.json`, `SKILLS.md` (regenerated if the catalog check runs on this machine).

- [ ] 3.1 For each of the 14 root skills rewrite `description:` as one line <= 250 chars (plain scalar, or double-quoted if it contains `: ` or `#`): what it does, then `Use when` with the 2-4 strongest trigger phrases from the old description, quoted verbatim. Drop `or invokes /<name>` and secondary prose. Follow the `caveman` example in `design.md`. Leave `grill-me`, `handoff` and `un-claudish` unchanged (already short, no `invokes /`) and `setup-repo-skills` unchanged (`disable-model-invocation: true`, not listed, exempt). The other 10 change: caveman, gh-issues-by-severity, grid-help, mine-learnings, openspec-help, rubber-duck, skill-scout, spec-scout, standup, tighten. Change no other frontmatter key and no body text.
- [ ] 3.2 Set `per_entry_max_chars` to 250 in `docs/budget-target.json`, then run `python3 scripts/budget.py --update-target` and commit the lowered totals.
- [ ] 3.3 If `baseline-submodules.txt` exists locally with initialised submodules, run `bash scripts/catalog.sh` and commit `SKILLS.md`; otherwise leave `SKILLS.md` alone (the catalog check skips there).
- [ ] 3.4 Add a case to `tests/test_budget.bats`: on the real repo (`GRID_DIR` = repo root), every listed `skills/*/SKILL.md` description (no `disable-model-invocation: true`) is one line <= 250 chars and none contains `invokes /`.

Acceptance: new case passes; `python3 scripts/budget.py --check` passes with `per_entry_max_chars: 250`; owned skills total in `--report` is at least 30% below group 1's figure.
Verify: `bash scripts/gate.sh`.

## 4. Split long owned skill bodies into sections

Depends on: 3 (same files) and 1.

Files: `skills/mine-learnings/`, `skills/openspec-help/`, `skills/setup-repo-skills/`, `skills/skill-scout/`, `skills/spec-scout/`, `skills/grid-help/`, `skills/un-claudish/` (each `SKILL.md` plus new `sections/*.md`), `scripts/budget.py`, `docs/budget-target.json`, `tests/test_budget.bats`, `CLAUDE.md`.

- [ ] 4.1 For every owned `SKILL.md` over 4,000 bytes at the start of this task (re-list with `wc -c skills/*/SKILL.md`), keep in `SKILL.md`: frontmatter, purpose, the numbered step skeleton, and a `## Sections` index in the format in `design.md`. Move reference tables, templates, long examples, checklists and per-case detail into `sections/<topic>.md` (plain markdown, no frontmatter, <= 6,000 bytes each, kebab-case names). Do not change wording or behaviour.
- [ ] 4.2 Equivalence check, recorded in the PR body: for each skill, `comm -23 <(git show "$(git merge-base HEAD origin/next)":skills/<n>/SKILL.md | grep -v '^\s*$' | sort -u) <(cat skills/<n>/SKILL.md skills/<n>/sections/*.md | sort -u)` prints nothing.
- [ ] 4.3 Extend `scripts/budget.py --check` with the sections integrity rule: every `sections/*.md` is referenced by a `- sections/<file>:` line in `SKILL.md`, every referenced path exists, no section exceeds 6,000 bytes, and `SKILL.md` <= `skill_body_max_bytes`. Set `skill_body_max_bytes` to 4000 in `docs/budget-target.json`.
- [ ] 4.4 Tests in `tests/test_budget.bats`: unreferenced section fails; missing referenced section fails; oversize `SKILL.md` fails; a skill without `sections/` under the limit passes; wiring a mock skill with `sections/` into a temp `SKILLS_DIR` via `wire.sh` keeps `sections/foo.md` readable through the symlink.
- [ ] 4.5 Add the `sections/` convention (3 lines) to `CLAUDE.md` under "Adding a skill".

Acceptance: `wc -c skills/*/SKILL.md` shows none above 4,000; equivalence output in the PR is empty; new tests green.
Verify: `bash scripts/gate.sh`.

## 5. Usage extractor with adapter seam

Depends on: foundations#2.

Files: `scripts/usage/extract.py`, `scripts/usage/adapters/__init__.py`, `scripts/usage/adapters/claude_code.py` (all new), `tests/test_usage_extract.bats` (new), `tests/fixtures/usage/claude-projects/` (new synthetic `.jsonl`), `tests/fixtures/usage/fake_adapter.py` (new).

- [ ] 5.1 Write `scripts/usage/adapters/__init__.py` with `REGISTRY = [ClaudeCode]` and a docstring stating the adapter contract (`name`, `available()`, `events(since_day)`, `wired()`; event shapes exactly as in `design.md`) and "to add a harness: new module + one REGISTRY line". Do not implement other harnesses.
- [ ] 5.2 Write `scripts/usage/adapters/claude_code.py` per `design.md` section 3 (port the logic; do not import the research `usage.py`). Emit only skill / agent / slash / listing events. Never emit prompt text.
- [ ] 5.3 Write `scripts/usage/extract.py`: `--out DIR` (default `${GRID_PRIVATE_DIR:-~/.the-grid-private}/usage`), `--host`, `--since-day`; `--registry MODULE:ATTR` (test hook: import a replacement registry list, default `adapters:REGISTRY`); run every `available()` adapter; merge per the max-merge rule into `<DIR>/<host>.json`; atomic write; skip the write when unchanged; print a one-line summary and the retention warning per `design.md`.
- [ ] 5.4 Fixtures (synthetic names only): a transcript tree with two projects, one `subagents/` file, a `/handoff` slash, a pasted-path "slash" (`/tmp/x/y`), a `skill_listing` attachment, a bad JSON line, the marker `SECRET-PROMPT-TEXT` in a prompt, across three UTC days. `fake_adapter.py` defines a `Fake` adapter and `REGISTRY = [Fake]` yielding fixed events.
- [ ] 5.5 Tests in `tests/test_usage_extract.bats`, with `CLAUDE_PROJECTS_DIR`, `SKILLS_DIR`, `AGENTS_DIR`, `CLAUDE_SETTINGS`, `GRID_PRIVATE_DIR` all pointing at temp dirs (copy the fixture tree to a temp dir first): (a) counts per day/kind match hand-counted expectations; (b) the path-like slash and any name failing the regex are absent; (c) the output contains neither `SECRET-PROMPT-TEXT` nor `sessionId`; (d) second run leaves the file byte-identical and its mtime unchanged; (e) deleting the oldest day's transcript copy and re-running keeps that day's counts; (f) `--registry` pointed at `fake_adapter:REGISTRY` (with `PYTHONPATH` set to the fixtures dir) yields counts under `harnesses.fake`; (g) retention warning appears for a missing setting and for `30`, not for `60`; (h) a missing projects dir exits 0 with a "no adapters available" line.

Acceptance: `tests/lib/bats-core/bin/bats tests/test_usage_extract.bats` green.
Verify: `bash scripts/gate.sh`.

## 6. Weekly job, per-OS schedulers, usage doc

Depends on: 5.

Files: `scripts/usage/weekly.sh`, `scripts/usage/install-schedule.sh`, `scripts/usage/schedule/com.the-grid.usage.plist.tmpl`, `scripts/usage/schedule/grid-usage.service.tmpl`, `scripts/usage/schedule/grid-usage.timer` (all new), `docs/usage.md` (new), `tests/test_usage_schedule.bats` (new), `scripts/gate.sh` (shellcheck glob), `CLAUDE.md`.

- [ ] 6.1 Write `scripts/usage/weekly.sh` per `design.md` section 4. Env: `GRID_PRIVATE_DIR`, `GRID_STATE_DIR`, `GRID_HOST`. Commit message `usage: <host> <YYYY-MM-DD>`, no AI attribution. Only `usage/<host>.json` is staged. Pull and push failures are logged to `$STATE/usage.log`, never fatal. A private dir that is not a git repo is fine (file only).
- [ ] 6.2 Write the scheduler templates with `@GRID_DIR@` placeholders: launchd `StartCalendarInterval` Weekday 1 Hour 9 Minute 0, stdout/stderr to `@STATE_DIR@/usage.log`; systemd service `Type=oneshot`, `ExecStart=/bin/bash @GRID_DIR@/scripts/usage/weekly.sh`; timer `OnCalendar=Mon 09:00`, `Persistent=true`, `RandomizedDelaySec=1h`, `WantedBy=timers.target`.
- [ ] 6.3 Write `scripts/usage/install-schedule.sh [--dry-run|--uninstall]` per `design.md` section 4 (`GRID_OS`, `LAUNCH_AGENTS_DIR`, `SYSTEMD_USER_DIR` overrides). Darwin: write plist, `launchctl bootout` then `bootstrap gui/$(id -u)`. Linux with `systemctl --user`: write units, `daemon-reload`, `enable --now grid-usage.timer`. Otherwise print `0 9 * * 1 bash <GRID_DIR>/scripts/usage/weekly.sh` and install nothing. `--dry-run` writes files and calls no `launchctl`/`systemctl`. Print the `loginctl enable-linger` note on Linux when `$DISPLAY` and `$WAYLAND_DISPLAY` are unset; never run it. Second run rewrites identical files; `--uninstall` removes exactly the installed files.
- [ ] 6.4 Write `docs/usage.md`: what is collected (and not), file schema, retention explanation, the `"cleanupPeriodDays": 60` settings line, per-OS install commands, how to read `usage/<host>.json`, how to add an adapter.
- [ ] 6.5 Tests in `tests/test_usage_schedule.bats` (stub `launchctl` and `systemctl` with scripts placed first on `PATH`; set `CLAUDE_PROJECTS_DIR` to a temp copy of the group 5 fixture tree, `GRID_STATE_DIR` and `GRID_PRIVATE_DIR` to temp dirs, `GRID_HOST=testhost`): (a) `weekly.sh` against a temp private git repo with a local bare remote creates one commit containing only `usage/<host>.json` and pushes it; (b) second run makes no new commit; (c) with the remote URL pointed at a missing path the job exits 0, keeps the commit and logs the push failure; (d) with a non-git private dir it writes the file and exits 0; (e) `install-schedule.sh --dry-run` with `GRID_OS=Darwin`, `Linux` and `Other` produces files (or the printed line) with no leftover `@GRID_DIR@`/`@STATE_DIR@` and no absolute path outside the temp dirs and the repo; (f) installing twice gives identical files; `--uninstall` removes them; (g) the plist passes `plutil -lint` when `plutil` exists, and the units pass `systemd-analyze verify --user` when available (skip otherwise).
- [ ] 6.6 Add `scripts/usage/*.sh` to the `shellcheck` line in `scripts/gate.sh`; add a Key files line to `CLAUDE.md`.

Acceptance: new tests green; shellcheck clean on the new scripts.
Verify: `bash scripts/gate.sh`.

## 7. Aggregator and prune report

Depends on: 5, and 1 (uses `scripts/lib/baseline_wired.py`).

Files: `scripts/usage/aggregate.py`, `scripts/usage/prune_report.py`, `scripts/prune-report.sh`, `docs/prune-keep.txt` (all new), `tests/test_prune_report.bats` (new), `tests/fixtures/usage/hosts/` (new per-host JSON), `docs/usage.md`, `CLAUDE.md`.

- [ ] 7.1 Write `scripts/usage/aggregate.py` with importable `aggregate(dir, window_days)` per `design.md` section 5. No CLI.
- [ ] 7.2 Write `scripts/usage/prune_report.py` and the thin `scripts/prune-report.sh` wrapper (`--window-days 90 --rare 2 --min-days 28 --usage-dir --out --json`; honours `GRID_DIR`). Candidate skills come from `baseline_wired()`; if it returns `None`, print "no baseline on this machine" and exit 0. Implement the state rule, keep list, insufficient-history stop, proposals A/B/C, numbered output ordered by chars saved, the `skillOverrides` JSON block, and the evidence footer. It writes nothing except stdout or `--out`.
- [ ] 7.3 Create `docs/prune-keep.txt` (a comment header plus `handoff`, `grid-help`).
- [ ] 7.4 Fixtures: two host files `hostA.json`, `hostB.json` in `tests/fixtures/usage/hosts/` covering >= 40 days, one skill used on hostA only, one repo whose skills are all unused, one `rare` skill, one agent never used. In the test, build a mock grid with `make_skill`, a temp baseline file (`GRID_BASELINE`) and `repos/`.
- [ ] 7.5 Tests in `tests/test_prune_report.bats`: (a) `aggregate()` sums both hosts, `hosts == 2`, correct coverage; (b) a skill used on only one host is `used`, not proposed; (c) the all-unused repo yields proposal A; (d) the `rare` and `never` skills yield `name-only` lines and a block that parses as JSON with a `skillOverrides` object; (e) keep-listed names never appear in proposals; (f) with coverage under 28 days the output says insufficient history and lists no proposals; (g) the run changes no file: hash the mock grid and usage dir before and after; (h) `--json` output parses and its counts match the markdown.
- [ ] 7.6 Document the report and its caveats in `docs/usage.md`; add Key files lines to `CLAUDE.md`.

Acceptance: new tests green; `bash scripts/prune-report.sh --usage-dir tests/fixtures/usage/hosts` exits 0 and `git status --porcelain` is empty afterwards.
Verify: `bash scripts/gate.sh`.

## 8. HUMAN: install schedules, set retention, review and apply the first prune

Depends on: 2, 3, 4, 6, 7 merged to `next`.

Files: none in the repo. Per machine: `~/.claude/settings.json`; the local `baseline-submodules.txt` and `machines/<host>.txt` (gitignored, personal).

- [ ] 8.1 On each machine: `git pull`, recompose agents (public projects and any private project, per CLAUDE.md "Existing machine" step 3), `bash scripts/wire.sh`.
- [ ] 8.2 Add `"cleanupPeriodDays": 60` to `~/.claude/settings.json` on each machine.
- [ ] 8.3 Run `bash scripts/usage/install-schedule.sh` on each machine; on headless Linux also `loginctl enable-linger`. Run `bash scripts/usage/weekly.sh` once by hand and confirm `usage/<host>.json` reaches the private repo's remote.
- [ ] 8.4 After at least 4 weeks of data from at least 2 machines, run `bash scripts/prune-report.sh --out "$HOME/.grid/prune.md"`, read it, and choose which numbered proposals to apply. Apply by editing `baseline-submodules.txt` or `machines/<host>.txt`, or pasting the `skillOverrides` block, then `bash scripts/wire.sh` and `python3 scripts/budget.py --update-target` (targets only go down).
- [ ] 8.5 Check the next weekly file: `listing` in `usage/<host>.json` shows fewer chars and dropped skills stay dropped.

Acceptance: every machine has a weekly `usage:` commit in the private repo; a decision (apply or skip) is recorded for each prune proposal.
Verify: `python3 scripts/budget.py --report` on each machine, plus `git -C ~/.the-grid-private log --oneline -- usage/`.
