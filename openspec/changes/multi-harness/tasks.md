# Tasks

Every group is one PR to `next`. Default verify command: `bash scripts/gate.sh`. All tests use temp dirs (`GRID_DIR`, `SKILLS_DIR`, `AGENTS_DIR`, `GRID_HARNESS_HOME`); none may touch the real home. Bats files needing PyYAML skip when `agent-factory/.venv` is absent, like `tests/test_compose_lint.bats`.

## 1. Harness registry and skill wiring

Depends on: none.

- [ ] 1.1 Create `scripts/lib/harnesses.tsv` with the seven rows from design.md (`compose_target` all `-` except `claude` = `claude-code`).
- [ ] 1.2 Create `scripts/lib/harness.sh` (sourced, shellcheck-clean): `harness_rows`, `harness_field <name> <col>`, `harness_expand_path` (expands `~` to `${GRID_HARNESS_HOME:-$HOME}`), `harness_active_set`, and the `RULES_DIST` constant. Unknown harness name exits 2 listing valid names.
- [ ] 1.3 Create `scripts/lib/skill_frontmatter.py` (stdlib only, run as `python3 -I`) printing `name` and `description` for a `SKILL.md`, handling plain, quoted and `>`/`|` block scalars.
- [ ] 1.4 Create `scripts/lib/skill-portable.sh` implementing `skill_portable <dir>` with the five ordered reasons from design.md.
- [ ] 1.5 Edit `scripts/wire.sh`: parse `harness:` / `-harness:` in `load_manifest` (before the `*)` case); add `--harness a,b` flag and `GRID_HARNESS` env; record wired skills in a list; tear down grid-owned symlinks in every registry dir; add step 3e (link portable skills and composed agents per active non-claude harness, dedupe by dir); write `skill@<dir>` / `agent@<dir>` manifest rows with skip reasons; extend `--check` to diff every registry dir under a throwaway `GRID_HARNESS_HOME`.
- [ ] 1.6 Edit `tests/helpers/setup.bash`: export `GRID_HARNESS_HOME` to a temp dir in `common_setup`; extend `assert_sandboxed` to refuse a `GRID_HARNESS_HOME` equal to the real home.
- [ ] 1.7 Create `tests/test_harness_wiring.bats` covering every scenario in `specs/harness-wiring/spec.md`. Acceptance: default run creates no harness dir other than claude's; `--harness codex,opencode` creates one `skills` set in `$GRID_HARNESS_HOME/.agents/skills`; a skill referencing `~/.claude` is absent there and present in claude's dir; second run is byte-identical; `-harness:codex` in an overlay removes its links; a real directory in the target is left alone; `wire.sh --check` exits 1 after a stale link is added.
- [ ] 1.8 Create `docs/harnesses.md`: the verified-facts table from design.md (with fetch date and URLs), the registry columns, how to activate a harness (`harness:codex` in `machines/<host>.txt`). Add a short "Harnesses" section to `CLAUDE.md` pointing at it. Add the `harness:` grammar line to `machines/example.txt` and `baseline-submodules.example.txt` comments.
- Verify: `bash scripts/gate.sh`; `tests/lib/bats-core/bin/bats tests/test_harness_wiring.bats tests/test_wiring.bats`. Existing `test_wiring.bats` must pass unmodified.

## 2. Golden-output scaffolding and shared agent emitter

Depends on: none (can run in parallel with 1). Folds #23.

- [ ] 2.1 Edit `agent-factory/compose.py`: extract the body of `emit_cc_subagent` (full profile) into `render_subagent_body(agent, slug, project_context="")`; `emit_cc_subagent` calls it. No change to Claude output.
- [ ] 2.2 Edit `agent-factory/compose.py`: add env `GRID_USER_CONFIG` (path override for `USER_CONFIG_PATH`, read once at import). Create `agent-factory/user.public.yaml` (`operator: ""`, `machine: your-machine`, `channels: ""`). Also add env `GRID_OPENCLAW_ROSTER` (path override for `openclaw/roster.json`) so a fixture roster can name the fixture orchestrator.
- [ ] 2.3 Edit `agent-factory/compose.py`: add a dispatch table `AGENT_TARGETS = {}` (target name to a function `(agent, slug) -> (filename, contents)`), a generic `write_harness_agents(target, name, config, out_dir)` writing specialists only to `<out>/<name>/_<target>/agents/`, and register it in the `--target` choices, `--check` writers and `--dry-run` paths. The table is empty in this group; later groups add one entry each. Refuse to write through a symlinked dir, as `write_claude_code` does.
- [ ] 2.4 Create fixtures: `tests/fixtures/harness/roles/{fx-specialist,fx-readonly,fx-lead}/` (role.yaml, SOUL.md, SKILL.md; `fx-readonly` has `tools: [Read, Grep, Glob, Bash]`; `fx-lead` has `orchestrator: true`), `tests/fixtures/harness/config.yaml` (slug `fx`, `fx-lead` delegates to the other two), `tests/fixtures/harness/models.yaml`.
- [ ] 2.5 Create `tests/lib/golden.bash`: `assert_golden <target>` composes the fixture config into a temp dir with `GRID_PRIVATE_ROLES_DIR`, `GRID_MODELS_FILE`, `GRID_USER_CONFIG` set to fixtures, then diffs against `tests/golden/<target>/`. `GRID_UPDATE_GOLDEN=1` rewrites the golden dir; the helper fails if that variable is set while `CI` is set.
- [ ] 2.6 Create `tests/test_golden.bats` with goldens for the existing targets `claude-code` and `openclaw-native` (fixture `roster.json` at `tests/fixtures/harness/roster.json` naming `fx-lead`); commit the generated `tests/golden/` trees. `paperclip` has a hard-coded role roster and is left out (Non-goal here). Acceptance: editing one byte of an emitter makes the matching test fail; re-running with `GRID_UPDATE_GOLDEN=1` fixes it; unchanged runs are byte-identical.
- [ ] 2.7 Create `scripts/compose-harnesses.sh`: for each public config in `agent-factory/examples/` composes `claude-code` plus the `compose_target` of every active harness (via `scripts/lib/harness.sh`); `--check` passes through to `compose.py --check`. Skips with a notice if the venv is absent. Add a `--dry-run` flag that prints the `compose.py` command lines instead of running them; test it in `tests/test_golden.bats` by asserting the printed list for `harness:codex` active.
- [ ] 2.8 Add an orphan check to `tests/lib/golden.bash` (`assert_no_orphans <target>`): every file under a composed `_<target>/agents/` maps to a role in the config; used by every target's golden test. Acceptance: copying a stray `.md` into the output dir makes the test fail.
- Verify: `bash scripts/gate.sh`. Also run `agent-factory/.venv/bin/python agent-factory/compose.py agent-factory/examples/grid.yaml --target claude-code --check` before and after on a composed machine; both must pass with no diff.

## 3. Codex target

Depends on: 1, 2.

- [ ] 3.1 Edit `agent-factory/compose.py`: add `CC_TO_CODEX_SANDBOX` logic and `emit_codex_agent(agent, slug)` returning `<slugged>.toml` per design.md (keys in order `name`, `description`, `sandbox_mode` when applicable, `developer_instructions`); add the hand-written TOML string escaper; register `"codex"` in `AGENT_TARGETS`.
- [ ] 3.2 Edit `scripts/lib/harnesses.tsv`: set the `codex` row `compose_target` to `codex`.
- [ ] 3.3 Create `tests/golden/codex/` from the fixture config (via `GRID_UPDATE_GOLDEN=1`) and add the `codex` golden test. Acceptance: `fx-readonly.toml` contains `sandbox_mode = "read-only"`, `fx-specialist.toml` has no `sandbox_mode` and no `model`; no file is written for `fx-lead`.
- [ ] 3.4 Create `tests/lib/validate_harness.py` (stdlib only) with `codex-agent <file>`: parses with `tomllib`, requires `name`, `description`, `developer_instructions` strings. Add a test running it on every golden `.toml` and on a body containing `\`, `"""` and a non-ASCII character.
- [ ] 3.5 Add wiring tests in `tests/test_harness_wiring.bats`: with `harness:codex` active and a stub composed `_codex/agents/x.toml` under a temp grid, `wire.sh` links it into `$GRID_HARNESS_HOME/.codex/agents/`, and a second run changes nothing.
- [ ] 3.6 Update `docs/harnesses.md` with the Codex row (agent format, sandbox mapping).
- Verify: `bash scripts/gate.sh`; `bats tests/test_golden.bats tests/test_harness_wiring.bats`.

## 4. Gemini CLI target (and Antigravity skills)

Depends on: 1, 2.

- [ ] 4.1 Edit `agent-factory/compose.py`: add the Claude-to-Gemini tool map from design.md, `E_TOOL_UNMAPPED` error, and `emit_gemini_agent(agent, slug)` returning `<slugged>.md`; register `"gemini-cli"` in `AGENT_TARGETS`.
- [ ] 4.2 Edit `scripts/lib/harnesses.tsv`: set the `gemini` row `compose_target` to `gemini-cli`.
- [ ] 4.3 Create `tests/golden/gemini-cli/` and the golden test. Acceptance: `fx-readonly.md` lists `read_file`, `read_many_files`, `grep_search`, `glob`, `list_directory`, `run_shell_command` in that order; `fx-specialist.md` has no `tools` and no `model`; a role with `tools: [Teleport]` makes compose exit non-zero with `E_TOOL_UNMAPPED` and writes nothing.
- [ ] 4.4 Add `gemini-agent <file>` to `tests/lib/validate_harness.py` (frontmatter `name` matches `^[a-z0-9_-]+$`, `description` present) and run it over the goldens.
- [ ] 4.5 Add wiring tests: `harness:gemini` links agents into `.gemini/agents/` and skills into `.agents/skills/`; `harness:antigravity` links skills into `.gemini/antigravity-cli/skills/` and creates no agents dir.
- [ ] 4.6 Update `docs/harnesses.md` (Gemini and Antigravity rows; the 2026-06-18 transition note; unverified Antigravity path caveat).
- Verify: `bash scripts/gate.sh`.

## 5. OpenCode target

Depends on: 1, 2.

- [ ] 5.1 Edit `agent-factory/compose.py`: add `emit_opencode_agent(agent, slug)` returning `<slugged>.md` with `description`, `mode: subagent` and the `permission` mapping from design.md; register `"opencode"` in `AGENT_TARGETS`.
- [ ] 5.2 Edit `scripts/lib/harnesses.tsv`: set the `opencode` row `compose_target` to `opencode`.
- [ ] 5.3 Create `tests/golden/opencode/` and the golden test. Acceptance: `fx-readonly.md` has `edit: deny` and `webfetch: deny` but no `bash` key; `fx-specialist.md` has no `permission` block; neither has `model`.
- [ ] 5.4 Add `opencode-agent <file>` to `tests/lib/validate_harness.py` (`description` present, `mode` equals `subagent`) and run it over the goldens.
- [ ] 5.5 Add a skills-name test: every skill linked into the shared dir after a wire run over fixture skills satisfies `^[a-z0-9]+(-[a-z0-9]+)*$` and matches its `SKILL.md` name (reuse `skill_portable` from group 1).
- [ ] 5.6 Add wiring tests for `harness:opencode` (agents into `.config/opencode/agents/`). Update `docs/harnesses.md`, including the `OPENCODE_DISABLE_CLAUDE_CODE_SKILLS=1` duplicate-listing note.
- Verify: `bash scripts/gate.sh`.

## 6. Pi

Depends on: 1.

- [ ] 6.1 Confirm the `pi` row in `scripts/lib/harnesses.tsv` (shared skills dir, no agents dir, rules `~/.pi/agent/AGENTS.md`); no code change expected beyond group 1.
- [ ] 6.2 Add tests in `tests/test_harness_wiring.bats`: with only `harness:pi` active, skills are linked into `.agents/skills/`, `.pi/agent/agents` is never created, and `wire.sh --check` passes.
- [ ] 6.3 Add `skill-name-collision` test: two wired skills of the same name from repo and root resolve to the root copy once (Pi keeps the first discovered and warns on collision, so duplicates must never be linked).
- [ ] 6.4 Update `docs/harnesses.md` Pi row; state "no subagent emitter: Pi documents no sub-agents".
- Verify: `bash scripts/gate.sh`.

## 7. OpenClaw

Depends on: 1, 2.

- [ ] 7.1 Check `tests/golden/openclaw-native/` exists from group 2, is non-empty (contains `fx-lead/AGENTS.md`), and its test passes.
- [ ] 7.2 Add a test that `harness:openclaw` links skills into `.agents/skills/` and writes nothing to any OpenClaw workspace, state dir or `openclaw.json`.
- [ ] 7.3 Update `docs/harnesses.md` OpenClaw row: skills via shared dir; agents via `compose.py --target openclaw-native` plus `agent-factory/scripts/deploy_openclaw.sh` (live deploy untouched); note the symlink realpath rule and the `skills.load.allowSymlinkTargets` setting for linked grid skills.
- [ ] 7.4 Comment on and close #3 as superseded (record the issue number in the PR body; Gareth closes).
- Verify: `bash scripts/gate.sh`.

## 8. Rules delivery

Depends on: 1; waits for workstream 8 (`rule-packs`) to define `dist/rules/<harness>.md`. If WS8 has not landed, merge this group with the placement logic and tests only (fixtures stand in for WS8 output).

- [ ] 8.1 Add `harness_install_rules <harness>` and `harness_remove_rules <harness>` to `scripts/lib/harness.sh`: managed-block insert/replace/remove per design.md, sha256 in the begin marker, `GRID_RULES_MAX_BYTES` cap (default 8192), no write when unchanged, atomic write via temp file plus `mv`.
- [ ] 8.2 Edit `scripts/wire.sh`: call them for each active harness with a `rules_file`, only when `$RULES_DIST/<harness>.md` exists; remove the block for registry harnesses that are inactive and have a block.
- [ ] 8.3 Create `tests/test_harness_rules.bats`. Acceptance: file absent is created with only the block; existing text above and below the markers is preserved byte-for-byte across two runs; a changed source replaces only the block; no dist file means no write and no new file; a 9000-byte source exits non-zero and leaves the file unchanged; deactivating removes the block and deletes a file that is then empty.
- [ ] 8.4 Update `docs/harnesses.md` with the instruction-file column and the cap.
- Verify: `bash scripts/gate.sh`.

## 9. Portable personas

Depends on: 2.

- [ ] 9.1 Edit `agent-factory/compose.py`: add `--target portable` writing `<out>/personas/<role>.md` (`# <Title>` then `render_subagent_body` with empty slug) for every role in the config, without deleting other files.
- [ ] 9.2 Create `scripts/build-personas.sh`: sets `GRID_PRIVATE_ROLES_DIR=` and `GRID_USER_CONFIG=agent-factory/user.public.yaml`, wipes `dist/personas/`, composes `core`, `grid`, `finance-desk`, `learning-desk`; `--check` composes to a temp dir and diffs; skips with a notice if the venv is absent.
- [ ] 9.3 Edit `scripts/gate.sh`: add a `personas` check running `build-personas.sh --check` (skipped loudly without the venv).
- [ ] 9.4 Run the script and commit `dist/personas/*.md`.
- [ ] 9.5 Create `tests/test_personas.bats`. Acceptance: output has no YAML frontmatter; no line contains `@` followed by a dotted domain, the local hostname, or any non-empty value from the local `agent-factory/user.yaml`; two runs are byte-identical; editing a role's `SOUL.md` makes `--check` exit 1; a role present in two configs yields identical output.
- [ ] 9.6 Add a pointer line to `docs/harnesses.md` ("single-file personas for ChatGPT / Claude Projects: `dist/personas/<role>.md`"). README wording belongs to workstream 12.
- Verify: `bash scripts/gate.sh`.

## 10. HUMAN: smoke test on real harnesses

Depends on: 1, 3, 4, 5. Needs the harnesses installed; Codex is the only one on the drafting Mac.

- [ ] 10.1 Codex: activate `harness:codex`, run `compose-harnesses.sh` and `wire.sh`; confirm `codex` lists a wired skill that carries `allowed-tools`, `triggers` and `version` frontmatter (extra fields accepted?), starts a session without a skills error, and spawns `grid-qa-engineer` by name from a symlinked `~/.codex/agents/*.toml`.
- [ ] 10.2 Gemini CLI and Antigravity: confirm which one is in use; on `agy` confirm the real global skills path (`~/.gemini/antigravity-cli/skills` vs `~/.antigravity`); on Gemini CLI confirm the `tools` YAML list is accepted and a symlinked agent file loads.
- [ ] 10.3 OpenCode: confirm `permission` mapping loads, and record whether a skill present in both `~/.claude/skills` and `~/.agents/skills` is listed twice.
- [ ] 10.4 Pi and OpenClaw: confirm shared-dir skills load (Pi `/skill:<name>`; OpenClaw symlink rule).
- [ ] 10.5 Optional, Cursor (#30): confirm shared-dir skills load and whether `.claude/agents` output is read.
- [ ] 10.6 Record each result with date in the `docs/harnesses.md` "Verified on a real install" table; open a follow-up issue for any failure (stripped-copy skills, copy-with-marker agents, path correction).
- Verify: none automated; the PR is the updated table.
