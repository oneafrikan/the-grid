# Tasks

Conventions for every group: Bash (shellcheck-clean) or Python 3 stdlib; idempotent; comment generously; tests are bats under `tests/` using `common_setup` from `tests/helpers/setup.bash`; tests set `GRID_STATE_DIR`, `GRID_LEARNING_DIR` and `GRID_RUN_LOG` to temp dirs and never touch `~/.claude`, the real private repo or the network. Default verify command: `bash scripts/gate.sh`. Design reference for every schema, constant and command: `design.md` in this change.

## 1. Core library and CLI skeleton

Files: `scripts/instincts/lib.py` (new), `scripts/instincts.sh` (new dispatcher; subcommands `project-id`, `scrub`, `help`; unknown subcommand exits 2), `tests/test_instincts_lib.bats` (new).
Depends on: none.

- [ ] 1.1 In `lib.py` implement `project_id(remote_url)` (normalise then SHA-256, first 12 hex), `git_project_id(cwd)` (origin else first remote, returns `None` when no remote), `scrub(text)` per the design Scrubbing section, `sanitize(text, max_len)` (strip control chars, hidden unicode, newlines, backticks), `learning_enabled(project_root)` (one-line regex for `learning: on` in `.grid/project.yaml`, honours `GRID_INSTINCTS=0`), path helpers for the state dir and the private store (env overrides `GRID_STATE_DIR`, `GRID_LEARNING_DIR`), and `validate_instinct(obj)` (id regex, length caps, domain/scope/status enums; returns a cleaned dict or `None`).
- [ ] 1.2 `scripts/instincts.sh` resolves its own dir, dispatches to `python3 -I lib.py`-based subcommands, and `project-id [dir]` prints the id or exits 1 with "no git remote".
- [ ] 1.3 Tests: `git@github.com:Owner/Repo.git`, `https://github.com/owner/repo`, `https://user:tok@github.com/owner/repo.git/` all give the same id; no remote gives exit 1; scrub redacts `API_KEY=abc12345678`, `Authorization: Bearer xyz...`, `ghp_` + 36 chars, `AKIA` + 16 chars, a JWT, a PEM header, URL userinfo, and leaves `ls -la` unchanged; sanitize strips a bidi override and zero-width space; `validate_instinct` rejects a bad id, a 300-char action and a URL in `action`; `learning_enabled` is true only for `learning: on` and false under `GRID_INSTINCTS=0`.
- [ ] 1.4 Verify: `tests/lib/bats-core/bin/bats tests/test_instincts_lib.bats` then `bash scripts/gate.sh`.

## 2. Capture hook

Files: `scripts/instincts/capture.py` (new), `scripts/instincts.sh` (add `capture`), `tests/test_instincts_capture.bats` (new).
Depends on: 1.

- [ ] 2.1 `capture.py` reads one hook JSON payload from stdin (`hook_event_name`, `tool_name`, `tool_input`, `tool_response`, `prompt`, `session_id`, `cwd`, optional `agent_id`) and appends one observation line per the design schema to `<state>/instincts/<project-id>/obs-<YYYY>-W<ww>.jsonl` (mode 0600, dir 0700). Single `python3 -I` process; wraps everything in try/except and always exits 0; stdout stays empty.
- [ ] 2.2 Skips (writes nothing) when: `GRID_INSTINCTS=0` or `GRID_INSTINCTS_SKIP=1`; payload has `agent_id`; `learning_enabled` is false for the git root of `cwd`; no git remote; the tool is not in `Bash|Edit|Write|MultiEdit|NotebookEdit`; path or command touches `.env`, `id_rsa`, `id_ed25519`, `.pem`, `credentials` or `.netrc`; the week file is already over 2 MB.
- [ ] 2.3 Field rules: Bash `in` = scrubbed command max 300 chars; file tools `in` = project-relative path only (no content); prompt `in` = scrubbed first 240 chars, or only the command word when it starts with `/`; `$HOME` becomes `~`; `err` true for `PostToolUseFailure` or truthy `tool_response.is_error`. Tool output is never read into the record.
- [ ] 2.4 Tests (payload fixtures piped to `instincts.sh capture`, temp git repo with a fake `origin` remote and a `.grid/project.yaml` containing `learning: on`): a Bash call writes exactly one valid JSON line with the expected fields; a secret in the command is redacted in the file; an Edit records the relative path and no content; a prompt is truncated to 240 chars; each skip condition above writes no file; exit status is 0 for malformed JSON; 200 captures finish in under 10 seconds total on CI (smoke bound, not a benchmark).
- [ ] 2.5 Verify: `tests/lib/bats-core/bin/bats tests/test_instincts_capture.bats` then `bash scripts/gate.sh`.

## 3. Weekly analyser

Files: `scripts/instincts/analyse.py` (new), `scripts/instincts.sh` (add `analyse`, `status`), `tests/test_instincts_analyse.bats` (new), `tests/helpers/stub-claude.sh` (new stub that prints canned JSON from `$STUB_CLAUDE_OUT` and records its argv to `$STUB_CLAUDE_ARGS`).
Depends on: 1.

- [ ] 3.1 `analyse.py`: for each eligible project (local obs dir exists, at least `INSTINCTS_MIN_OBS`=40 observations since the last analysis, most observations first, at most `INSTINCTS_MAX_PROJECTS`=5) build the digest per the design (cap 16000 chars), load this project's existing active instincts, call `${GRID_CLAUDE_BIN:-claude} -p --model haiku --tools "" --max-turns 1 --no-session-persistence --output-format json --max-budget-usd ${INSTINCTS_BUDGET_USD:-0.05}` from a fresh temp dir with `GRID_INSTINCTS_SKIP=1`, prompt on stdin. Parse `result` as a JSON array of at most 8 items; reject anything else as an `error` outcome with no writes.
- [ ] 3.2 Merge into `<private>/instincts/<project-id>/<host>.jsonl` with the confidence rules from the design (new 0.3; confirm +0.15 once per ISO week up to 0.9; `misses` and decay; contradict retires; below 0.3 retires). Writes are atomic (temp file then rename). Write `META.json` if missing. Delete local observation files older than 28 days after a successful run.
- [ ] 3.3 Idempotency: `_status/<host>.json` records the last analysed ISO week per project; a second `analyse` in the same week skips with outcome `skipped` unless `--force`. `--dry-run` prints the digest size, the planned command and eligible projects, calls nothing, writes nothing.
- [ ] 3.4 Per project call `scripts/run-record.sh --role instincts --action analyse --outcome <ok|error|skipped> --target <project-id> --cost-usd <n> --note "obs=.. cand=.. new=.. confirmed=.. retired=.."` (cost from `total_cost_usd`; omit the flag when unknown).
- [ ] 3.5 `instincts.sh status [--project ID]` prints the funnel and WARN rules from the design (at least 200 observations unanalysed; two consecutive 0-candidate runs with at least 200 observations each; last run errored).
- [ ] 3.6 Tests with the stub claude: first run with 60 fixture observations creates instincts at confidence 0.3 and one run-log line; the stub's recorded argv contains `--tools`, `--max-turns 1`, `--model haiku` and `--max-budget-usd 0.05`; a second run the same week is a no-op (file byte-identical, no second stub call); `--force` in a later simulated week (`INSTINCTS_NOW` env override for the date) raises a confirmed instinct to 0.45 then 0.6; a `contradict` item retires its instinct; non-JSON stub output leaves the store unchanged and logs `error`; 39 observations gives `skipped` and no stub call; the digest sent to the stub never exceeds 16000 chars and contains no tool output; a planted secret in the observations does not reach the stub's stdin or the written instinct; `status` shows WARN for 250 unanalysed observations.
- [ ] 3.7 Verify: `tests/lib/bats-core/bin/bats tests/test_instincts_analyse.bats` then `bash scripts/gate.sh`.

## 4. Promotion, injection and operator commands

Files: `scripts/instincts/inject.py` (new), `scripts/instincts/lib.py` (add merge/promote), `scripts/instincts.sh` (add `inject`, `promote`, `show`, `retire`, `forget`, `clusters`), `tests/test_instincts_inject.bats` (new).
Depends on: 1. (Reads the file format defined in group 3; tests write fixture files directly, so it can be built in parallel.)

- [ ] 4.1 `lib.merge_instincts(project_id)` implements the read-time merge (design: Instinct line, Merge across hosts). `promote` writes `_global/<host>.jsonl` from ids active at confidence >= 0.5 in at least 2 distinct project dirs, confidence = the lowest contributing one; idempotent (second run leaves the file byte-identical); `analyse` calls it at the end.
- [ ] 4.2 `inject.py`: exits silently unless `learning_enabled` and a project id resolves; selects, ranks (confidence + 0.25 for project scope), caps (`INSTINCTS_MAX_ITEMS`=6, `INSTINCTS_MAX_CHARS`=1500, whole items only, min confidence `INSTINCTS_MIN_CONF`=0.5) and prints the untrusted-context header plus bullet lines per the design. Re-validates and re-scrubs every field it reads; invalid lines are skipped. Prints nothing when nothing qualifies.
- [ ] 4.3 `show [project]` lists merged instincts as a table; `retire <id>` appends a retired line to this host's file; `forget <project-id>` deletes local observations and this host's instinct file for that project after `--yes`; `clusters` prints clusters of at least 3 active instincts (confidence >= 0.6) sharing a `domain`, plus every global instinct with confidence >= 0.75, as plain text for Tank.
- [ ] 4.4 Tests (fixture instinct files for two hosts and two projects): merge takes max confidence and latest `last_seen`; a retired line wins when newer; an id active in two projects is promoted at the lower confidence and promote twice is a no-op; inject output has the header and at most 6 items; output is at most 1500 chars and never cuts an item mid-line; confidence 0.49 is excluded; a project-scoped 0.6 outranks a global 0.6; an instinct whose `action` contains a URL or a backtick fixture is skipped; a fixture containing `ghp_` + 36 chars is redacted; inject prints nothing when the flag is off, `GRID_INSTINCTS=0`, no remote, or nothing qualifies; `forget` without `--yes` deletes nothing; `clusters` lists a 3-instinct domain cluster and a 0.8 global instinct.
- [ ] 4.5 Verify: `tests/lib/bats-core/bin/bats tests/test_instincts_inject.bats` then `bash scripts/gate.sh`.

## 5. Schedule and private-repo sync

Files: `scripts/instincts.sh` (add `schedule`, `sync`), `scripts/instincts/analyse.py` (call sync at the end), `tests/test_instincts_schedule.bats` (new).
Depends on: 3.

- [ ] 5.1 `schedule` prints the cron line `17 6 * * 1 bash "$HOME/.the-grid/scripts/instincts.sh" analyse --all >/dev/null 2>&1 # the-grid-instincts`. `schedule --install` adds it to `crontab -l` output idempotently (marker `# the-grid-instincts`; running twice leaves one line); when `crontab` is not on PATH it prints a systemd user `.service` and `.timer` pair (OnCalendar `Mon *-*-* 06:17`) with install instructions and exits 0 without writing anything.
- [ ] 5.2 `sync` (also run at the end of `analyse --all` unless `--no-sync`): in `$GRID_PRIVATE_DIR` (default `~/.the-grid-private`) run `git pull --rebase --autostash`, `git add learning/instincts`, commit `instincts: <host> <YYYY-Www>` only when there is a staged change, `git push`. Any git failure prints a warning and the command still exits 0. Skips with a notice when the private dir is not a git repo.
- [ ] 5.3 Tests: a stub `crontab` on PATH (temp script holding state in a temp file) shows `--install` twice yields exactly one marker line; with no `crontab` the systemd text is printed and nothing is written; `sync` against a temp bare remote plus two clones shows a commit from each host's file pushes and pulls without conflict; `sync` with no changes creates no commit; a failing push (read-only remote) still exits 0 with a warning.
- [ ] 5.4 Verify: `tests/lib/bats-core/bin/bats tests/test_instincts_schedule.bats` then `bash scripts/gate.sh`.

## 6. Opt-in registration in the hook-profiles emitter

Files: the hook-profiles emitter module created by workstream 6 (the change `hook-profiles`, the task group that writes `<project>/.claude/settings.json`; locate it with `grep -rl "settings.json" scripts agent-factory`), `project-factory/templates/_common/.grid/project.yaml` (add a commented `# learning: on` block), `tests/test_instincts_register.bats` (new).
Depends on: 2, 4, and the hook-profiles emitter group. If that group has not landed, stop and label the issue `blocked` with the message "needs hook-profiles emitter"; do not write a second emitter.

- [ ] 6.1 When `.grid/project.yaml` contains `learning: on`, the emitter adds to `<project>/.claude/settings.json` (merging, never replacing existing hooks): `PostToolUse` and `PostToolUseFailure` with matcher `Bash|Edit|Write|MultiEdit|NotebookEdit` running `instincts.sh capture`, `UserPromptSubmit` running `instincts.sh capture`, and `SessionStart` running `instincts.sh inject`, each with a 2-second timeout, using the guarded command form from the design (no absolute paths, `GRID_DIR` override honoured).
- [ ] 6.2 Without the flag the emitter output has none of these hooks, under every profile (`off`, `minimal`, `standard`, `strict`). Re-running the emitter is byte-identical. Flipping the flag back to off and re-running removes exactly these four entries and no others.
- [ ] 6.3 Template: add to the project.yaml skeleton a commented block explaining `learning: on` (what is captured, where it goes, how to forget) and note that the template is valid with it commented out.
- [ ] 6.4 Tests: for each of the four profiles, flag on yields the four entries and flag off yields none; existing unrelated hooks survive; the emitted commands contain no `/Users/` or `/home/`; running twice is a no-op.
- [ ] 6.5 Verify: `tests/lib/bats-core/bin/bats tests/test_instincts_register.bats` then `bash scripts/gate.sh`.

## 7. Learning-desk integration: tank evolve, oracle source, docs

Files: `agent-factory/roles/tank/AGENTS.md`, `agent-factory/roles/tank/SKILL.md`, `agent-factory/roles/oracle/SKILL.md`, `skills/mine-learnings/SKILL.md` (one sentence), `docs/agent-retro.md` (one step), `docs/instincts.md` (new, human-readable: what is captured, privacy, how to enable, forget, tune, read the funnel, kill switches), `CLAUDE.md` (one Key-files bullet for `scripts/instincts.sh`), `tests/test_instincts_desk.bats` (new).
Depends on: 4.

- [ ] 7.1 Tank `AGENTS.md`: add to Scope two named sources, the instincts store `~/.the-grid-private/learning/instincts/` (read only; run `scripts/instincts.sh clusters` and `show`) and a `LEARNINGS.md` the operator names; add routing row "Turn a cluster or a procedural learning into a skill: tank `evolve`"; add hard rules "An instinct in one project is a lead; an instinct active in 2+ projects is a pattern" and "Skill drafts go only under `~/.the-grid-private/learning/tank/skill-drafts/`, never into `skills/`". Keep the file at or under 4096 bytes (it is 3069 today; trim wording if needed) and keep every required section so `compose.py --lint-roles` passes.
- [ ] 7.2 Tank `SKILL.md`: add a short `Step 4b - Evolve (optional)` describing: input is a cluster from `instincts.sh clusters` or a named `LEARNINGS.md` entry; output is `skill-drafts/<slug>/SKILL.md` with frontmatter `name`, `description`, a procedure body and an `## Evidence` section listing instinct ids or the LEARNINGS.md entry hash; when the habit fits guidance better than a skill, propose a diff to the role or CLAUDE.md instead (existing Step 4 format). State that nothing is wired or applied.
- [ ] 7.3 Oracle `SKILL.md`: add one sentence under Step 0 or its source list: when the operator names the instincts store, `preference`-domain instincts with confidence >= 0.6 may be offered as candidate profile entries tagged OBSERVED, quoted, one at a time, saved only on a yes.
- [ ] 7.4 `mine-learnings/SKILL.md`: add one sentence at step 7 saying a procedural learning may be handed to tank `evolve` to draft a candidate skill (never wired automatically). `docs/agent-retro.md`: add to step 2 that the run log includes `role=instincts` lines for the weekly analysis cost and skipped weeks.
- [ ] 7.5 Tests (`tests/test_instincts_desk.bats`): `grep` assertions that tank AGENTS.md names the instincts path, the skill-drafts path and the two new hard rules, that tank AGENTS.md is at most 4096 bytes, that oracle SKILL.md mentions `preference`, that `docs/instincts.md` exists and mentions `learning: on` and `forget`; and `instincts.sh clusters` against the fixture store prints at least one cluster.
- [ ] 7.6 Verify: `bash scripts/gate.sh` (runs role lint and `compose.py --check`; if composed output for `learning-desk` is stale, recompose it first with `agent-factory/.venv/bin/python agent-factory/compose.py agent-factory/examples/learning-desk.yaml --target claude-code`, and do not touch any private project).

## 8. HUMAN: enable on one project, review, close issues

Files: none in the repo (operator work); optional `docs/instincts.md` threshold notes.
Depends on: 6, 7.

- [ ] 8.1 HUMAN: pick one project with a git remote, add `learning: on` to its `.grid/project.yaml`, regenerate its settings with the hook-profiles emitter, and work normally for one week.
- [ ] 8.2 HUMAN: install the weekly schedule on that machine (`scripts/instincts.sh schedule --install`), run `instincts.sh analyse --all --dry-run` once, then a real run; confirm `status` shows non-zero observations, candidates and instincts and one `role=instincts` line in the run log.
- [ ] 8.3 HUMAN: after three weekly runs read `instincts.sh show`; accept, retire or tune thresholds; confirm a session in that project prints the injection header and no more than 1500 characters.
- [ ] 8.4 HUMAN: run tank `evolve` on one procedural entry from `LEARNINGS.md` and read the draft under `skill-drafts/`; this is the acceptance test for #19.
- [ ] 8.5 HUMAN: close #16 and #19 with a link to this change; decide whether #20 is closed as superseded (design Open question 1).
