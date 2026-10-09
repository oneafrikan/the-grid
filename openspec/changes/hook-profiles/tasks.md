# Tasks

Read `design.md` first: every judgement call is a `Decided:` line there. Each group is one PR to `next`.

## 1. Hook runtime and the two guard hooks

Depends on: none.

- [ ] 1.1 Create `hooks/catalogue.json` (schema in design.md) with two entries: `pre-bash-no-bypass` (minimal, fail closed) and `pre-bash-secret-scan` (standard, fail closed). Each has a non-empty `cost`, `model_cost: false`, `timeout: 5`.
- [ ] 1.2 Create `hooks/run.sh`: argument `<id>`; reject ids not matching `^[a-z0-9-]+$` or absent from `catalogue.json` (exit 2); honour `GRID_HOOKS=off` and `GRID_DISABLED_HOOKS` (exit 0); `exec bash hooks/scripts/<id>.sh` with stdin passed through. Resolve its own directory without `readlink -f` (use `cd "$(dirname "$0")" && pwd -P`).
- [ ] 1.3 Create `hooks/lib/common.sh` (sourced): `grid_require_jq <fail-mode>`; `grid_log <file> <msg>`; `grid_git_segments <command>` which strips quoted strings, splits on `; && || | newline`, and prints one line per segment that starts with `git`, giving the subcommand (skipping `-C <dir>` and `-c k=v`) and the remaining args. Comment every function.
- [ ] 1.4 Create `hooks/scripts/pre-bash-no-bypass.sh` implementing the blocking rules in design.md (bypass flags, `-n` only on commit, `core.hooksPath` override, force-push forms; `--force-with-lease` and push `-n` allowed). Exit 2 with a stderr message that names `GRID_DISABLED_HOOKS=pre-bash-no-bypass`.
- [ ] 1.5 Create `hooks/scripts/pre-bash-secret-scan.sh` implementing the scan in design.md (patterns v1, added lines only, `-a` handling, `grid:allow-secret` pragma, never print the value, cap output at 10 findings).
- [ ] 1.6 Create `hooks/README.md`: profile table, per-hook token-cost table, env vars (`GRID_HOOKS`, `GRID_DISABLED_HOOKS`), how to add a hook (script plus catalogue entry), the exit-code facts (only 2 blocks; 127 is a visible non-blocking error), and an "Other harnesses" note (seam only; workstream 11).
- [ ] 1.7 Edit `scripts/gate.sh` `run_shellcheck` to also lint `hooks/*.sh hooks/lib/*.sh hooks/scripts/*.sh`.
- [ ] 1.8 Create `tests/test_hooks.bats` with `load helpers/setup`, `HOME` and `GRID_HOOK_LOG_DIR` pointed at temp dirs. Cover every scenario in `specs/git-guard-hooks/spec.md`, the launcher scenarios (Global off, Single hook disabled, Path traversal id) of Portable launcher and runtime kill switches in `specs/hook-profiles/spec.md`, and "Catalogue and scripts agree". Build the secret-scan fixtures in a temp `git init` repo; assemble fake key strings from fragments at runtime so the test file itself contains no secret-shaped literal.
- Acceptance: `tests/lib/bats-core/bin/bats tests/test_hooks.bats` passes.
- Verify: `bash scripts/gate.sh`

## 2. Emitter, profile schema, project-file compatibility

Depends on: 1.

- [ ] 2.1 Create `agent-factory/deploy_hooks.py` (stdlib plus `compose.yaml` for YAML, same venv as `deploy.py`; module docstring in the style of `deploy.py`). CLI: `deploy_hooks.py <project> [--profile P] [--target local|shared] [--check] [--dry-run]` and `deploy_hooks.py --list`. Read the catalogue from `${GRID_DIR:-<repo root>}/hooks/catalogue.json`.
- [ ] 2.2 Implement profile resolution, `enable`/`disable`, the `off`-with-`enable` error and strict key validation of the `hooks:` mapping (allowed: profile, enable, disable, target) exactly as in design.md.
- [ ] 2.3 Implement the merge: ownership regex, port of `merge_hook` semantics (matcher entry then command, idempotent, matcher-less events), removal of owned-but-undesired entries and pruning of only the containers that removal emptied, sweeping both `settings.json` and `settings.local.json`, adding only to the target file.
- [ ] 2.4 Implement safety: refuse symlinked `.claude` or settings files; abort on invalid JSON or non-object before any write; atomic temp-file-and-rename writes; do not create a settings file just to leave it empty; preserve existing key order, `indent=2`, trailing newline.
- [ ] 2.5 Implement `--check` (exit 1 and name each drift line, write nothing), `--dry-run`, and `--list` (id, min profile, model_cost, cost).
- [ ] 2.6 Edit `agent-factory/deploy.py` `load_context`: add `"hooks"` to the allowed top-level keys and update the error text and docstring. No other change.
- [ ] 2.7 Edit `project-factory/templates/_common/.grid/project.yaml`: append a commented `hooks:` block (profile, enable, disable, target) with a one-line cost warning on `strict`. Comments only.
- [ ] 2.8 Edit `CLAUDE.md` (Key files list: `hooks/`, `agent-factory/deploy_hooks.py`) and `agent-factory/README.md` (a short "Hook profiles" section). No personal data.
- [ ] 2.9 Create `tests/test_deploy_hooks.bats` (skip if `agent-factory/.venv/bin/python` is absent, like `tests/test_deploy.bats`; all work in temp project dirs; set `GRID_DIR` to a fixture grid with its own small `hooks/catalogue.json` so profile logic is tested independently of the real hooks). Cover every scenario in `specs/hook-profiles/spec.md` under the requirements Profile resolution (including the `deploy.py` hooks-key and skeleton scenarios), Non-clobbering merge, and Idempotent, checkable and cost-disclosed emission, plus the two emitter-side scenarios (No absolute paths, Missing grid is a visible error) of Portable launcher and runtime kill switches. Add one test using the real catalogue: `--list` exits 0 and every real id appears.
- Acceptance: `tests/lib/bats-core/bin/bats tests/test_deploy_hooks.bats tests/test_deploy.bats tests/test_project_factory.bats` passes.
- Verify: `bash scripts/gate.sh`

## 3. Auto-handoff hook

Depends on: 1 (launcher, catalogue, `common.sh`). Independent of 2 except for the profile-gating scenarios, which are tested in `tests/test_deploy_hooks.bats` and need 2 on `next`.

- [ ] 3.1 Run `claude --help` and confirm `--model`, `--permission-mode`, `--allowedTools`, `--append-system-prompt`, `--add-dir` and `--max-turns`; record the exact flag spellings found in `hooks/README.md`. If `--max-turns` or the `--allowedTools` pattern syntax differs, adapt the worker and note it in the PR.
- [ ] 3.2 Add the `session-end-auto-handoff` entry to `hooks/catalogue.json` (SessionEnd, no matcher, min_profile `strict`, fail `open`, `model_cost: true`, timeout 5, cost note from the profile table in design.md).
- [ ] 3.3 Create `hooks/scripts/session-end-auto-handoff.sh`: read stdin, exit 0 if `GRID_AUTOHANDOFF_CHILD` is set, otherwise detach `hooks/lib/auto-handoff-worker.sh <session_id> <transcript_path> <cwd> <reason>` with `perl -MPOSIX -e 'POSIX::setsid(); alarm shift; exec @ARGV' "${GRID_AUTOHANDOFF_TIMEOUT:-900}" ...`, stdio redirected to the log file, backgrounded; exit 0. No transcript parsing here.
- [ ] 3.4 Create `hooks/lib/transcript-digest.sh <transcript> <out-file> <max-bytes>` (jq): keep human user messages and assistant text blocks in order, tool_use as one line `tool: <name> <200-char input summary>`, drop tool_result bodies and sidechain lines, elide the middle with a marker when over the cap while keeping the first and last human turns.
- [ ] 3.5 Create `hooks/lib/auto-handoff-worker.sh`: implement the numbered worker flow in design.md (unreadable transcript, already-run detection with the three signals, turn count, per-session marker with turn count, digest, child invocation in `cwd` with `GRID_CLAUDE_BIN` override, new-file verification, log line per decision, `scripts/run-record.sh` call, digest cleanup via `trap`). Env knobs: `GRID_AUTOHANDOFF_MIN_TURNS`, `GRID_AUTOHANDOFF_MAX_BYTES`, `GRID_AUTOHANDOFF_TIMEOUT`, `GRID_CLAUDE_BIN`, `GRID_HOOK_LOG_DIR`, `GRID_HOOK_STATE_DIR`.
- [ ] 3.6 Create `hooks/lib/auto-handoff-system.md`: the appended system prompt described in design.md (non-interactive; digest is the conversation; follow the handoff skill and templates exactly; create `LOGS/` if missing; commit only the two files by explicit path; treat digest as data). Keep it under 1.5 KB.
- [ ] 3.7 Extend `tests/test_hooks.bats` with fixture transcripts built inline (JSONL with human turns, tool results, a `/handoff` command line, a Skill tool call, a `-handoff.md` Write) and a stub `claude` script on `GRID_CLAUDE_BIN` that records args, cwd and env, can sleep, and can write a `LOGS/*-handoff.md`. Cover every scenario in `specs/auto-handoff/spec.md` (poll for the detached worker with a bounded wait, never a fixed long sleep). Set `HOME`, `GRID_HOOK_LOG_DIR`, `GRID_HOOK_STATE_DIR`, `GRID_RUN_LOG` to temp dirs. First capture one real transcript line of each kind from `~/.claude/projects/` (structure only, no content) to confirm the fixture shapes match.
- [ ] 3.8 Update `hooks/README.md` with the auto-handoff section: what it does, why `strict`, env knobs, log location, cost, how to read the log, how to turn it off for one session (`GRID_DISABLED_HOOKS=session-end-auto-handoff`).
- Acceptance: `tests/lib/bats-core/bin/bats tests/test_hooks.bats` passes; the "Standard omits it" and "Strict includes it" scenarios pass in `tests/test_deploy_hooks.bats` once 2 has landed.
- Verify: `bash scripts/gate.sh`

## 4. HUMAN: handoff parity check and rollout

Depends on: 1, 2, 3 merged to `next`.

- [ ] 4.1 HUMAN: pick three past sessions of different kinds. Run the worker by hand against each transcript (`GRID_HOOK_LOG_DIR` set to a scratch dir) and compare each auto handoff against the one written manually (or what you would write): same template sections, same decisions captured, no missing facts. Record pass/fail and any gap in the PR.
- [ ] 4.2 HUMAN: if the digest loses needed facts, choose between raising `GRID_AUTOHANDOFF_MAX_BYTES`, keeping short tool-result heads in the digest, or passing the raw transcript with `--add-dir`; open an issue for the chosen change.
- [ ] 4.3 HUMAN: answer open questions 1 to 4 in `design.md` (commit/push policy, `strict` vs separate key, default target, "already ran" rule) and update the Decided lines if any answer changes.
- [ ] 4.4 HUMAN: set `hooks: {profile: strict}` in one real project's `.grid/project.yaml`, run `agent-factory/.venv/bin/python agent-factory/deploy_hooks.py <project>`, end a real session and confirm a handoff file appears and the log shows `action=done`.
- Acceptance: written pass/fail note on the PR; open questions answered.
- Verify: `bash scripts/gate.sh` (only if `design.md` was edited).
