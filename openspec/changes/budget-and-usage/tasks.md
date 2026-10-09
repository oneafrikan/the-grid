# Tasks

Default verify command: `bash scripts/gate.sh`. All tests are bats under `tests/` and use temp dirs plus the `GRID_DIR`, `SKILLS_DIR`, `AGENTS_DIR`, `GRID_HOST` overrides; none may read the real `~/.claude`, `~/.claude/projects` or `~/.the-grid-private`. Python is 3 stdlib only. New shell scripts must be shellcheck-clean (`shellcheck -S warning`). Comment code generously. No personal data (names, emails, hostnames, absolute `/Users` paths) in any tracked file. Design details and schemas are in `design.md`; do not re-decide anything listed under `## Decisions`.

## 1. Budget measurement and gate check

Depends on: none.

Files: `scripts/budget.py` (new), `scripts/lib/baseline_wired.py` (new), `docs/budget-target.json` (new), `scripts/gate.sh`, `tests/test_budget.bats` (new), `tests/fixtures/budget/` (new), `CLAUDE.md` (Key files).

- [ ] 1.1 Write `scripts/lib/baseline_wired.py`: `baseline_wired(grid_dir) -> list[dict]` with keys `name`, `source_dir`, `repo` (`repos/<repo>` name, or `owned` for `skills/`). It runs `wire.sh` into a temp `SKILLS_DIR`/`AGENTS_DIR` with `GRID_SKIP_CATALOG=1` and `GRID_HOST=__baseline__`, then reads the resulting symlinks; links whose target is under `agent-factory/projects/` are ignored. Returns `None` when `baseline-submodules.txt` is absent or `git submodule status` shows an uninitialised (`-`) submodule.
- [ ] 1.2 Write `scripts/budget.py` per `design.md` section 1: a stdlib scalar reader for `description:` / `summary:` (plain, single-quoted, double-quoted, `>`, `>-`, `|`, with whitespace collapsed); the three scopes; `--report`, `--check`, `--update-target`, `--allow-raise`, `--json`; exit 3 when only the baseline scope is skipped. Roles come from `agent-factory/roles/*/role.yaml` (skip `_retired`), using `description` if present else the legacy formula `"<title>. <summary> Use this subagent for <role> work."` (specialist) or `"<title> orchestrator. <summary> Invoke with /<role>."` (orchestrator). Honour `GRID_DIR`.
- [ ] 1.3 Create `docs/budget-target.json` with the schema in `design.md`, filled by running `python3 scripts/budget.py --update-target` on the current tree (so the gate passes at this commit). `skill_body_max_bytes` is set to the current largest owned `SKILL.md` for now; group 4 lowers it to 4000.
- [ ] 1.4 In `scripts/gate.sh` add a `budget` check (`run_budget_check`): runs `python3 scripts/budget.py --check`; exit 3 appends `budget-baseline` to `SKIPPED` and returns 0. Update the header comment list of checks.
- [ ] 1.5 Add `tests/test_budget.bats` using a mock grid under `tests/fixtures/budget/`: (a) totals match hand-counted fixture descriptions including a folded `>` scalar and a 2,000-char description cut at 1,536; (b) `--check` passes at the target and fails when a description grows by 1 char; (c) an owned entry over 180 chars fails `--check` and names the file; (d) `--update-target` lowers a number, and refuses to raise one without `--allow-raise`; (e) baseline scope is skipped with exit 3 when `baseline-submodules.txt` is absent and measured when a fixture baseline plus a fixture `repos/x/skills/y/SKILL.md` exist; (f) a machine overlay in `machines/<host>.txt` does not change the baseline number; (g) running twice gives identical `--json`.
- [ ] 1.6 Add one line for `scripts/budget.py` and `docs/budget-target.json` to `CLAUDE.md` Key files, including the rule "lowering a number is normal, raising one needs `--allow-raise` and review".

Acceptance: `tests/lib/bats-core/bin/bats tests/test_budget.bats` green; `python3 scripts/budget.py --check` exits 0 on this repo; `bash scripts/gate.sh` shows a `budget` check PASS.
Verify: `bash scripts/gate.sh`.

## 2. One-line role descriptions

Depends on: 1.

Files: `agent-factory/compose.py`, `agent-factory/roles/*/role.yaml` (38), `agent-factory/docs/role-authoring.md`, `docs/budget-target.json`, `tests/test_compose_lint.bats`, `tests/test_authoring_variants.bats` (or a new `tests/test_role_description.bats`), `CLAUDE.md`.

- [ ] 2.1 In `compose.py` add `description` to `ROLE_YAML_KEYS`; in `emit_cc_subagent` and `emit_cc_skill` use `role_meta(role)["description"]` verbatim (whitespace-collapsed) when present, else the existing formula. Also apply it wherever `deploy.py` builds `grid-<role>` frontmatter via the same functions (do not change its flags).
- [ ] 2.2 Add `description:` to every `agent-factory/roles/*/role.yaml`: one line, <= 180 chars, form `<Title>. <what it owns / when to reach for it>.`, no "Use this subagent" or "Invoke with" text, facts from the existing `summary:` only (do not invent capabilities). Keep `summary:` unchanged (rosters use it).
- [ ] 2.3 Add a "Description" paragraph to `agent-factory/docs/role-authoring.md`: required for new roles, one line, <= 180 chars, why (listing budget).
- [ ] 2.4 Tests: (a) a role with `description:` composes to a subagent whose frontmatter description equals it exactly and contains no `Use this subagent`; (b) an orchestrator composes to a skill with the same property and no `Invoke with`; (c) a role without `description:` composes exactly as before (golden string); (d) `compose.py --lint-roles` accepts the new key and still rejects a misspelt one.
- [ ] 2.5 Run `python3 scripts/budget.py --update-target` and commit the lowered `docs/budget-target.json`.
- [ ] 2.6 Recompose locally to confirm (`agent-factory/.venv/bin/python agent-factory/compose.py agent-factory/examples/core.yaml --target claude-code --check` is expected to report drift until recomposed; recompose all public projects, never wire). Note in the PR body that other machines must recompose after pulling.

Acceptance: new tests green; every `role.yaml` has a <= 180-char single-line `description`; `python3 scripts/budget.py --check` passes with the lowered roles totals.
Verify: `bash scripts/gate.sh`.

## 3. One-line owned skill descriptions

Depends on: 1.

Files: `skills/*/SKILL.md` (14 frontmatter blocks and the top of each body), `docs/budget-target.json`, `SKILLS.md` (regenerated), `tests/test_skill_format.bats` (only if a test asserts description wording).

- [ ] 3.1 For each of the 14 root skills rewrite `description:` as one plain-scalar line <= 180 chars: what it does, no "Use when ..." list, no `invoke /x` text. Keep `name`, `argument-hint`, `disable-model-invocation` and every other frontmatter key unchanged.
- [ ] 3.2 Add `## When to invoke` as the first body section of each skill containing the removed trigger phrases verbatim (bullets, e.g. `- "caveman mode", "spartan mode", "terse"`). Skills whose description had no triggers (`grill-me`, `handoff`, `un-claudish`) get no new section.
- [ ] 3.3 Run `bash scripts/catalog.sh` to regenerate `SKILLS.md` (the catalogue summary is the description's first sentence; it should barely change) and include it in the commit.
- [ ] 3.4 Run `python3 scripts/budget.py --update-target`; commit the lowered `docs/budget-target.json`.
- [ ] 3.5 Test: extend `tests/test_budget.bats` (or add a case in `tests/test_skill_format.bats`) asserting that on this real repo every `skills/*/SKILL.md` description is a single line <= 180 chars.

Acceptance: the new assertion passes; `bash scripts/catalog.sh --check` passes; owned skills total in `python3 scripts/budget.py --report` is at least 40% below the group 1 figure.
Verify: `bash scripts/gate.sh`.

## 4. Split long owned skill bodies into sections

Depends on: 3 (same files; merge after it) and 1.

Files: `skills/mine-learnings/`, `skills/openspec-help/`, `skills/setup-repo-skills/`, `skills/skill-scout/`, `skills/spec-scout/`, `skills/grid-help/`, `skills/un-claudish/` (each `SKILL.md` plus new `sections/*.md`), `scripts/budget.py`, `docs/budget-target.json`, `tests/test_budget.bats`, `CLAUDE.md`.

- [ ] 4.1 For each listed skill (every owned `SKILL.md` over 4,000 bytes at the start of this task; re-list with `wc -c skills/*/SKILL.md`), keep in `SKILL.md`: frontmatter, purpose, `## When to invoke`, the numbered step skeleton, and a `## Sections` index in the format in `design.md`. Move reference tables, templates, long examples, checklists and per-case detail into `sections/<topic>.md` (plain markdown, no frontmatter, <= 6,000 bytes each, kebab-case names). Do not change wording or behaviour.
- [ ] 4.2 Equivalence check, recorded in the PR body: for each skill every non-blank line of the pre-change `SKILL.md` appears in the new `SKILL.md` or one of its sections, except the lines this change adds or removes by design (index, `## When to invoke`, description). Command pattern: `git show HEAD~:skills/<n>/SKILL.md | sort -u` against `cat skills/<n>/SKILL.md skills/<n>/sections/*.md | sort -u`, with `comm -23` expected empty apart from those lines.
- [ ] 4.3 Extend `scripts/budget.py --check` with the sections integrity rule: every `sections/*.md` is referenced by a `- sections/<file>:` line in `SKILL.md`, every referenced path exists, no section exceeds 6,000 bytes, and `SKILL.md` <= `skill_body_max_bytes`. Set `skill_body_max_bytes` to 4000 in `docs/budget-target.json`.
- [ ] 4.4 Tests in `tests/test_budget.bats`: unreferenced section fails; missing referenced section fails; oversize `SKILL.md` fails; a skill without `sections/` and under the limit passes; wiring a skill with `sections/` into a temp `SKILLS_DIR` via `wire.sh` keeps `sections/foo.md` readable through the symlink.
- [ ] 4.5 Add the `sections/` convention (3 lines) to `CLAUDE.md` under "Adding a skill".

Acceptance: `wc -c skills/*/SKILL.md` shows none above 4,000; equivalence check output in the PR; new tests green.
Verify: `bash scripts/gate.sh`.

## 5. Usage extractor with adapter seam

Depends on: none.

Files: `scripts/usage/extract.py`, `scripts/usage/adapters/__init__.py`, `scripts/usage/adapters/claude_code.py` (all new), `tests/test_usage_extract.bats` (new), `tests/fixtures/usage/claude-projects/` (new synthetic `.jsonl`).

- [ ] 5.1 Write `scripts/usage/adapters/__init__.py` with `REGISTRY = [ClaudeCode]` and a short docstring stating the adapter contract (`name`, `available()`, `events(since_day)`, `wired()`; event shapes exactly as in `design.md`) and "to add Codex or Gemini: new module + one REGISTRY line". Do not implement other harnesses.
- [ ] 5.2 Write `scripts/usage/adapters/claude_code.py` porting the logic of `usage.py` (research folder; do not import it): stream `$CLAUDE_PROJECTS_DIR` (default `~/.claude/projects`) `**/*.jsonl` including `subagents/`, tolerate bad lines and unreadable files, emit skill / agent / slash / tokens / listing events, tokens deduped per message id, slash only from non-subagent files, UTC day from timestamp, name regex filter. `wired()` reads `$SKILLS_DIR` and `$AGENTS_DIR` (defaults `~/.claude/skills`, `~/.claude/agents`). Never emit prompt text.
- [ ] 5.3 Write `scripts/usage/extract.py`: `--out DIR` (default `${GRID_PRIVATE_DIR:-~/.the-grid-private}/usage`), `--host` (default `GRID_HOST` else `hostname -s`), `--since-day`; run every `available()` adapter; merge per the max-merge rule into `<DIR>/<host>.json`; atomic write; skip the write when unchanged; print a one-line summary and, if `~/.claude/settings.json` has no `cleanupPeriodDays` or one below 45, a one-line retention warning recommending 60 (read via `$CLAUDE_SETTINGS`, default `~/.claude/settings.json`).
- [ ] 5.4 Fixtures: a synthetic transcript tree with two projects, one `subagents/` file, a duplicated streamed assistant message id, a `/handoff` slash, a pasted-path "slash", a `skill_listing` attachment, a bad JSON line, across three UTC days.
- [ ] 5.5 Tests in `tests/test_usage_extract.bats`, with `CLAUDE_PROJECTS_DIR`, `SKILLS_DIR`, `AGENTS_DIR`, `CLAUDE_SETTINGS`, `GRID_PRIVATE_DIR` all pointing at temp dirs: (a) counts per day/kind match hand-counted expectations and the duplicated message id is counted once; (b) the path-like slash and any name failing the regex are absent; (c) the output JSON contains none of the strings placed in fixture prompt text (grep the file for a marker string such as `SECRET-PROMPT-TEXT`) and no `sessionId`; (d) second run leaves the file byte-identical and its mtime unchanged; (e) deleting the oldest fixture day's transcript and re-running keeps that day's counts (max-merge); (f) a fake adapter class (defined in a python helper under `tests/fixtures/usage/`) injected into `REGISTRY` yields counts under its own `harnesses.<name>` key, proving the extractor uses only the four-member contract; (g) retention warning appears for missing and for `30`, not for `60`; (h) missing projects dir exits 0 with a "no adapters available" line.

Acceptance: `tests/lib/bats-core/bin/bats tests/test_usage_extract.bats` green and `shellcheck` unaffected.
Verify: `bash scripts/gate.sh`.

## 6. Weekly job, per-OS schedulers, retention doc

Depends on: 5.

Files: `scripts/usage/weekly.sh`, `scripts/usage/install-schedule.sh`, `scripts/usage/schedule/com.the-grid.usage.plist.tmpl`, `scripts/usage/schedule/grid-usage.service.tmpl`, `scripts/usage/schedule/grid-usage.timer`, `docs/usage.md` (all new), `tests/test_usage_schedule.bats` (new), `scripts/gate.sh` (add the new scripts to the shellcheck glob), `CLAUDE.md`.

- [ ] 6.1 Write `scripts/usage/weekly.sh` per `design.md` section 4. Env: `GRID_PRIVATE_DIR`, `GRID_HOST`, `XDG_STATE_HOME`. Commit message `usage: <host> <YYYY-MM-DD>`, no AI attribution. Only `usage/<host>.json` is staged. Pull and push failures are logged, never fatal. A private dir that is not a git repo is fine (file only).
- [ ] 6.2 Write the three scheduler templates with `@GRID_DIR@` placeholders (launchd: Monday 09:00 `StartCalendarInterval`, output to the state log; systemd: `OnCalendar=Mon 09:00`, `Persistent=true`, `RandomizedDelaySec=1h`; service is `Type=oneshot` running `bash @GRID_DIR@/scripts/usage/weekly.sh`).
- [ ] 6.3 Write `scripts/usage/install-schedule.sh [--dry-run|--uninstall]`: Darwin -> launchd (write plist to `$LAUNCH_AGENTS_DIR`, default `~/Library/LaunchAgents`, `launchctl bootstrap gui/$(id -u)`); Linux with `systemctl --user` -> units into `$SYSTEMD_USER_DIR` (default `~/.config/systemd/user`), `daemon-reload`, `enable --now grid-usage.timer`; otherwise print the crontab line `0 9 * * 1 bash <GRID_DIR>/scripts/usage/weekly.sh` and install nothing. `--dry-run` writes into the override dirs only and calls no `launchctl`/`systemctl`. Print the `loginctl enable-linger` note on headless Linux; never run it. Idempotent: second run rewrites identical files, `--uninstall` removes exactly what was installed.
- [ ] 6.4 Write `docs/usage.md`: what is collected (and what is not), file schema, the retention explanation, the `cleanupPeriodDays: 60` recommendation with the exact settings.json line, per-OS install commands, how to read `usage/<host>.json`, how to add an adapter.
- [ ] 6.5 Tests in `tests/test_usage_schedule.bats` (override env vars; stub `launchctl`/`systemctl` on PATH where needed): (a) `weekly.sh` against a temp private git repo with a local bare remote creates one commit containing only `usage/<host>.json` and pushes it; (b) second run makes no new commit; (c) with the remote removed the job exits 0, leaves the commit, and logs the push failure; (d) with a non-git private dir it writes the file and exits 0; (e) `install-schedule.sh --dry-run` on each branch (force with `GRID_OS=Darwin|Linux|Other`) produces files with no leftover `@GRID_DIR@` and no `/Users` path other than the temp dir; (f) running the installer twice is a no-op diff; `--uninstall` removes the files; (g) the plist passes `plutil -lint` when `plutil` exists (skip otherwise); the unit files pass `systemd-analyze verify` when available (skip otherwise).
- [ ] 6.6 Add `scripts/usage/*.sh` to the shellcheck invocation in `scripts/gate.sh`; add a Key files line to `CLAUDE.md`.

Acceptance: new tests green; shellcheck clean on the new scripts.
Verify: `bash scripts/gate.sh`.

## 7. Aggregator and prune report

Depends on: 5, and 1 (uses `scripts/lib/baseline_wired.py`).

Files: `scripts/usage/aggregate.py`, `scripts/usage/prune_report.py`, `scripts/prune-report.sh`, `docs/prune-keep.txt` (all new), `tests/test_prune_report.bats` (new), `tests/fixtures/usage/hosts/` (new per-host JSON), `docs/usage.md`, `CLAUDE.md`.

- [ ] 7.1 Write `scripts/usage/aggregate.py` per `design.md` (importable `aggregate(dir, window_days)` and CLI `--dir --window-days --json`). Ignore files with unknown `schema` and non-JSON files; compute coverage from the earliest and latest `days` key across hosts; tokens rolled up by month and model.
- [ ] 7.2 Write `scripts/usage/prune_report.py` and the thin `scripts/prune-report.sh` wrapper (`--window-days 90 --rare 2 --min-days 28 --usage-dir --out --json`). Candidate skills come from `baseline_wired()`; if it returns `None`, print "no baseline on this machine" and exit 0. Implement the state rule, the keep list, the insufficient-history stop, proposals A/B/C, numbered output ordered by chars saved, the `skillOverrides` JSON block, and the evidence footer. It must write nothing except stdout or `--out`.
- [ ] 7.3 Create `docs/prune-keep.txt` (comments plus `handoff`, `grid-help`).
- [ ] 7.4 Fixtures: two host files in `tests/fixtures/usage/hosts/` covering >= 40 days, one skill used on host A only, one repo whose skills are all unused, one `rare` skill, one agent never used. A mock grid (via `make_skill` helpers) with a fixture `baseline-submodules.txt` and `repos/`.
- [ ] 7.5 Tests in `tests/test_prune_report.bats`: (a) aggregate sums across both hosts and reports `hosts=2` and correct coverage; (b) a skill used on only one host is `used`, not proposed; (c) the all-unused repo yields proposal A listing the used-skill exceptions (none here); (d) the `rare` and `never` skills yield `name-only` lines and a valid JSON `skillOverrides` block (parse it); (e) keep-listed names never appear in proposals; (f) with coverage under 28 days the output says insufficient history and lists no proposals; (g) the run changes no file: hash the mock grid, mock settings and usage dir before and after; (h) `--json` output parses and matches the markdown counts.
- [ ] 7.6 Document the report and its caveats in `docs/usage.md`; add Key files lines to `CLAUDE.md`; state there that `prune-report` becomes `grid prune-report` when the dispatcher exists.

Acceptance: new tests green; on this repo `bash scripts/prune-report.sh --usage-dir tests/fixtures/usage/hosts` runs and prints numbered proposals without modifying the working tree (`git status --porcelain` empty afterwards).
Verify: `bash scripts/gate.sh`.

## 8. HUMAN: install schedules, set retention, review and apply the first prune

Depends on: 2, 3, 4, 6, 7 merged to `next`.

Files: none in the repo. Per machine: `~/.claude/settings.json`; this repo's `baseline-submodules.txt` and `machines/<host>.txt` (gitignored, personal).

- [ ] 8.1 On each machine (macOS, Ubuntu, Arch, forge): `git pull`, recompose agents (public projects and any private project, per CLAUDE.md "Existing machine" step 3), `bash scripts/wire.sh`.
- [ ] 8.2 Add `"cleanupPeriodDays": 60` to `~/.claude/settings.json` on each machine.
- [ ] 8.3 Run `bash scripts/usage/install-schedule.sh` on each machine; on headless Linux also `loginctl enable-linger`. Run `bash scripts/usage/weekly.sh` once by hand and confirm `usage/<host>.json` appears in the private repo on the remote.
- [ ] 8.4 After at least 4 weeks of data from at least 2 machines, run `bash scripts/prune-report.sh --out /tmp/prune.md`, read it, and choose which numbered proposals to apply. Apply by editing `baseline-submodules.txt` or `machines/<host>.txt`, or pasting the `skillOverrides` block, then `bash scripts/wire.sh` and re-run `python3 scripts/budget.py --update-target` (the target only goes down).
- [ ] 8.5 Open the next weekly report to confirm the dropped skills stay dropped and the listing no longer truncates (check `listing` in `usage/<host>.json`).

Acceptance: every machine has a weekly `usage:` commit in the private repo; a decision (apply or skip) is recorded for each prune proposal.
Verify: `python3 scripts/budget.py --report` on each machine, plus `git -C ~/.the-grid-private log --oneline -- usage/`.
