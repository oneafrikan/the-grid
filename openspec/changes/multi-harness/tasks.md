# Tasks

Every group is one PR to `next`. Default verify command: `bash scripts/gate.sh`. Every test uses temp dirs (`GRID_DIR`, `SKILLS_DIR`, `AGENTS_DIR`, `GRID_HARNESS_HOME`) and never touches the real home. Bats files that need PyYAML skip when `agent-factory/.venv` is absent, as `tests/test_compose_lint.bats` does. This change merges after `loops` (D9), so `foundations`, `workflow-upgrades` and `rule-packs` are already on `next`.

## 1. Harness registry and shared-dir skill wiring

Depends on: rule-packs#2 (lands first in `load_manifest` and `tests/helpers/setup.bash`; rebase onto it).

- [ ] 1.1 Create `scripts/lib/harnesses.tsv` with the seven rows and header comment from design.md, verbatim.
- [ ] 1.2 Create `scripts/lib/harness.sh` (sourced, shellcheck-clean, commented): `harness_names` (registry names in file order), `harness_field <name> <column>` (columns: `skills_dir agents_dir compose_target rules_file rules_harness`), `harness_path <value>` (expands a leading `~` to `${GRID_HARNESS_HOME:-$HOME}`, echoes `-` unchanged), `harness_valid <name>`.
- [ ] 1.3 Create `scripts/lib/skill_frontmatter.py` (stdlib only, run as `python3 -I`, commented): prints `name<TAB>description` for a `SKILL.md` path, handling plain, single/double-quoted and `>`/`|` block scalars, newlines folded to spaces; exit 1 if there is no leading `---` block.
- [ ] 1.4 Create `scripts/lib/skill-portable.sh` with `skill_portable <dir>` returning the five ordered reasons from design.md.
- [ ] 1.5 Edit `scripts/wire.sh`:
  - (a) In `load_manifest`, parse `harness:*` into `WIRED_HARNESSES` and `-harness:*` as a subtraction. These cases go before `-*/*`.
  - (b) After the manifests load, compute `ACTIVE_HARNESSES`, where `GRID_HARNESS` (non-empty, comma list) replaces the manifest set. Drop `claude`. Validate every name with `harness_valid`. If a name is unknown, print the valid names to stderr and exit 2 before any teardown.
  - (c) Tear down grid-owned links in every non-claude registry `skills_dir`/`agents_dir`.
  - (d) Add step 3e per design.md. Use `skill@<~dir>` / `agent@<~dir>` manifest rows, with the skip reason as the last column.
  - (e) Extend the `--check` block: set `GRID_HARNESS_HOME="$tmp/home"` for the sub-run, then diff each distinct non-claude registry dir with the existing `links` function.
- [ ] 1.6 Edit `tests/helpers/setup.bash`: in `common_setup`, create `MOCK_HARNESS_HOME`, export it as `GRID_HARNESS_HOME`, and `unset GRID_HARNESS`. Extend `assert_sandboxed` to refuse a `GRID_HARNESS_HOME` that resolves (`pwd -P`) to `${REAL_HOME:-$HOME}`. Remove the temp dir and unset the vars in `common_teardown`.
- [ ] 1.7 Create `tests/test_harness_wiring.bats`, one test per scenario in `specs/harness-wiring/spec.md`. Fixtures are made with the existing `make_skill` helper plus one skill whose body contains `~/.claude/`, one whose frontmatter name differs from its dir, and one with a 1100-char description. Acceptance:
  - With no `harness:` entry, `$GRID_HARNESS_HOME` stays empty.
  - With `harness:codex` and `harness:opencode` in the overlay, each portable skill appears once in `$GRID_HARNESS_HOME/.agents/skills`, and the three non-portable ones are absent there but present in `$SKILLS_DIR`.
  - The skip reasons appear in `.wired.manifest`.
  - `GRID_HARNESS=pi` overrides the overlay.
  - `GRID_HARNESS=nonesuch` exits 2 and creates nothing.
  - A second run leaves the links and `.wired.manifest` byte-identical.
  - Adding `-harness:codex` and `-harness:opencode` removes the grid links but keeps a foreign link.
  - A real dir in the shared dir is skipped with "real dir, not managed".
  - `wire.sh --check` exits 0 after a wire, and exits 1 and names the link after a stale grid link is added to `.agents/skills`.
  - `assert_sandboxed` fails when `GRID_HARNESS_HOME=$HOME`.
- [ ] 1.8 Create `docs/harnesses.md`. Include the verified-facts table from design.md with its fetch date and sources, the shared-dir finding, the registry columns, activation (`harness:codex` in `machines/<host>.txt`, `GRID_HARNESS`), the skip reasons and how to read them in `.wired.manifest`, and the OpenCode duplicate-listing switch. Add a short "Harnesses" section to `CLAUDE.md` pointing at it. Add the `harness:` / `-harness:` grammar to the comments in `machines/example.txt` and `baseline-submodules.example.txt` (no active entries).
- Verify: `tests/lib/bats-core/bin/bats tests/test_harness_wiring.bats tests/test_wiring.bats` (the existing `test_wiring.bats` passes unmodified), then `bash scripts/gate.sh`.

## 2. Shared agent emitter plumbing and fixture role

Depends on: workflow-upgrades#2 (goldens, `scripts/compose-goldens.sh`, `GRID_USER_CONFIG`, fixtures under `tests/fixtures/compose/`). Can run in parallel with 1.

- [ ] 2.1 Edit `agent-factory/compose.py`: extract the full-profile body of `emit_cc_subagent` (from `procedure = ...` to the returned `body`) into `render_subagent_body(agent, slug, project_context="")`, and have `emit_cc_subagent` call it.
- [ ] 2.2 Edit `agent-factory/compose.py`: add `AGENT_TARGETS: dict[str, Callable[[dict, str], tuple[str, str]]] = {}` and `write_harness_agents(target, name, config, out_dir)` per design.md: refuse a symlinked `_<target>` dir, wipe it, write specialists only to `agents/`, and run every emit before the wipe so an emitter error writes nothing. In `main()`, build the `--target` choices from the existing four plus `sorted(AGENT_TARGETS)`, add each to the `--check` `writers` map, and add a `--dry-run` branch listing `<name> -> _<target>/agents/<file>`. The table stays empty in this group.
- [ ] 2.3 Add fixture role `tests/fixtures/compose/roles/fx-readonly/` (same file set as the other fixture roles, `tools: [Read, Grep, Glob, Bash]`) and add it as a specialist in `tests/fixtures/compose/fixture.yaml`. Run `bash scripts/compose-goldens.sh --update`. `git status` may show only new `fx-readonly` files plus files that list every agent (e.g. the `openclaw` target's `agents.yaml`); no existing role's file may change.
- Acceptance: `bash scripts/compose-goldens.sh --check` passes. `compose.py agent-factory/examples/grid.yaml --target claude-code --out <tmp>` gives byte-identical output before and after 2.1 (`diff -r` of two temp trees).
- Verify: `bash scripts/gate.sh`.

## 3. Codex target

Depends on: 1, 2.

- [ ] 3.1 Edit `agent-factory/compose.py`: add `toml_basic(s)` and `toml_multiline(s)` escapers and `emit_codex_agent(agent, slug)` returning `(<name>.toml, text)` per design.md, then register `"codex"` in `AGENT_TARGETS`.
- [ ] 3.2 Add `codex` to the target list in `scripts/compose-goldens.sh` and run `--update`. Acceptance: `golden/codex/.../fx-readonly.toml` contains `sandbox_mode = "read-only"`, the other specialist's file has neither `sandbox_mode` nor `model`, and no file exists for any orchestrator.
- [ ] 3.3 Create `tests/lib/validate_harness.py` (stdlib only) with `codex-agent FILE...`: each file parses with `tomllib` and has string `name`, `description` and `developer_instructions`. Python < 3.11 (no `tomllib`) prints a skip notice and exits 0. Create `tests/test_harness_formats.bats`. It runs the validator over every golden `.toml`, plus a round-trip test that writes a body containing `\`, `"""`, a tab and `é` through `toml_multiline`, parses it back and compares.
- [ ] 3.4 Add to `tests/test_harness_wiring.bats`: with `GRID_HARNESS=codex` and a stub `agent-factory/projects/p/_codex/agents/x.toml` in the temp grid, `x.toml` is linked into `$GRID_HARNESS_HOME/.codex/agents/`, and a second run changes nothing.
- [ ] 3.5 Add the Codex agent format and sandbox mapping, plus the compose command, to `docs/harnesses.md`.
- Verify: `tests/lib/bats-core/bin/bats tests/test_harness_formats.bats tests/test_harness_wiring.bats`, then `bash scripts/gate.sh`.

## 4. OpenCode target

Depends on: 1, 2, 3 (`validate_harness.py` and `test_harness_formats.bats` exist).

- [ ] 4.1 Edit `agent-factory/compose.py`: add `emit_opencode_agent(agent, slug)` returning `(<name>.md, text)` with `description`, `mode: subagent` and the `permission` mapping from design.md, and register `"opencode"`.
- [ ] 4.2 Add `opencode` to `scripts/compose-goldens.sh` and run `--update`. Acceptance: `fx-readonly.md` has `edit: deny` and `webfetch: deny` and no `bash` key, the other specialist has no `permission`, and neither file has `model`.
- [ ] 4.3 Add `opencode-agent FILE...` to `validate_harness.py`: frontmatter has a non-empty `description` and `mode: subagent`. Add `skill DIR...`: the dir name matches `^[a-z0-9]+(-[a-z0-9]+)*$` and is at most 64 chars, the frontmatter name equals the dir name, and the description is 1 to 1024 chars. Use `scripts/lib/skill_frontmatter.py`. In `test_harness_formats.bats`, run `opencode-agent` over the goldens, and run `skill` over every entry linked into `$GRID_HARNESS_HOME/.agents/skills` after a fixture wire.
- [ ] 4.4 Add to `tests/test_harness_wiring.bats`: `GRID_HARNESS=opencode` links stub `_opencode/agents/*.md` into `.config/opencode/agents/`.
- [ ] 4.5 Add the OpenCode row and compose command to `docs/harnesses.md`.
- Verify: `bash scripts/gate.sh`.

## 5. Gemini CLI target

Depends on: 1, 2, 3. Lower priority than 3 and 4 (operator answer). It can be left to the last night.

- [ ] 5.1 Edit `agent-factory/compose.py`: add `GEMINI_TOOLS` (the map from design.md), the `E_TOOL_UNMAPPED` check, and `emit_gemini_agent(agent, slug)`, then register `"gemini-cli"`.
- [ ] 5.2 Add `gemini-cli` to `scripts/compose-goldens.sh` and run `--update`. Acceptance: `fx-readonly.md` lists `read_file, read_many_files, grep_search, glob, list_directory, run_shell_command` in that order, and the other specialist has no `tools` and no `model`.
- [ ] 5.3 Add to `tests/test_harness_formats.bats`: a temp private-roles dir with a role whose `tools: [Teleport]` makes `compose.py --target gemini-cli --out <tmp>` exit 1 with `E_TOOL_UNMAPPED`, and leaves `<tmp>` without a `_gemini-cli` dir. Add `gemini-agent FILE...` to `validate_harness.py` (`name` matches `^[a-z0-9_-]+$` and `description` is non-empty) and run it over the goldens.
- [ ] 5.4 Add to `tests/test_harness_wiring.bats`: `GRID_HARNESS=gemini` links agents into `.gemini/agents/` and skills into `.agents/skills/`. `GRID_HARNESS=antigravity` links skills into `.gemini/antigravity-cli/skills/` and creates no agents dir.
- [ ] 5.5 Add the Gemini and Antigravity rows to `docs/harnesses.md`, with the 2026-06-18 transition note and the caveat that the Antigravity path is unverified.
- Verify: `bash scripts/gate.sh`.

## 6. Pi and OpenClaw (skills-only rows)

Depends on: 1.

- [ ] 6.1 Add to `tests/test_harness_wiring.bats`:
  - With `GRID_HARNESS=pi`, skills land in `.agents/skills/`, `.pi/agent/agents` is never created, and `wire.sh --check` exits 0.
  - With `GRID_HARNESS=openclaw`, skills land in `.agents/skills/` and nothing is created under `.openclaw/`.
  - When a root skill and a repo skill share a name, the shared dir holds one link, and it resolves to the root copy (Pi keeps the first skill it discovers, so duplicates must never be linked).
- [ ] 6.2 Add the Pi and OpenClaw rows to `docs/harnesses.md`:
  - Pi: "no subagent emitter: Pi documents no sub-agents".
  - OpenClaw: agents via `compose.py --target openclaw-native` plus `agent-factory/scripts/deploy_openclaw.sh` (unchanged), and the symlink realpath rule and `skills.load.allowSymlinkTargets` setting for linked grid skills.
- [ ] 6.3 Add a PR body line: "Supersedes #3 (OpenClaw emitter exists and is goldened; skills reach OpenClaw via the shared dir). Operator closes."
- Verify: `bash scripts/gate.sh`.

## 7. Rules delivery via `rules.py emit`

Depends on: 1, rule-packs#2 (`rules:<pack>` tier, wired-pack array), rule-packs#4 (`rules.py emit --harness agents-md|gemini --packs … --out PATH [--check]`, including empty-selection removal).

- [ ] 7.1 Edit `scripts/wire.sh`: add step 3f per design.md "Rules delivery".
  - For each active harness with a `rules_file` that exists, call `python3 "$GRID_DIR/scripts/rules.py" emit --harness <rules_harness> --packs <csv> --out <file>`.
  - For each inactive harness whose existing file contains the `rule-packs` BEGIN marker, make the same call with `--packs ''`.
  - When an active harness's file is absent, add a manifest row `rules@<~file>	<harness>	-	skipped	rules-file-absent`.
  - Collect `rules.py` failures, finish the remaining steps, then exit 1.
  - In the `--check` block, make the same calls with `--check`.
- [ ] 7.2 Create `tests/test_harness_rules.bats`. Fixture: a temp grid with `rules/fx/<topic>.md` (format per rule-packs) and `rules:fx` in the overlay. Acceptance:
  - With `GRID_HARNESS=codex` and no `$GRID_HARNESS_HOME/.codex/AGENTS.md`, no file is created and the manifest row says `rules-file-absent`.
  - With the file present and containing user text, the block appears and the user text is byte-identical. A second run leaves the file's checksum unchanged.
  - Removing `rules:fx` removes the block and keeps the user text.
  - Deactivating the harness removes the block.
  - `wire.sh --check` exits 1 after the block is hand-edited.
  - `GRID_HARNESS=antigravity` never touches `.gemini/GEMINI.md`.
- [ ] 7.3 Add the instruction-file column, the "create the file to opt in" rule, and the token-cost note (always-loaded block, capped by `rules.py`) to `docs/harnesses.md`.
- Verify: `bash scripts/gate.sh`.

## 8. Portable personas (#36)

Depends on: 2.

- [ ] 8.1 Edit `agent-factory/compose.py`: add `--target portable`. It writes `<out>/<name>/_portable/<role>.md` = `# <Title>\n\n` + `render_lean_body(agent, "")` for every role, orchestrators included. Wipe and refuse a symlinked dir, as the other writers do, and register it in `--check` and `--dry-run`.
- [ ] 8.2 Add `portable` to `scripts/compose-goldens.sh` and run `--update`.
- [ ] 8.3 Create `scripts/build-personas.sh` (shellcheck-clean, commented) per design.md, with `--check`. If `agent-factory/.venv` is absent, print a skip notice and exit 0.
- [ ] 8.4 Edit `scripts/gate.sh`: add one `check personas bash scripts/build-personas.sh --check` line with a comment, placed before the bats check.
- [ ] 8.5 Run `bash scripts/build-personas.sh` and commit `dist/personas/*.md`. Before committing, `grep -rnE '/Users/|/home/|@[a-z0-9-]+\.[a-z]' dist/personas` must print nothing. If it prints anything, stop and report it instead of committing.
- [ ] 8.6 Create `tests/test_personas.bats`. Acceptance:
  - No persona starts with `---`.
  - A second build is byte-identical.
  - In a temp copy of the repo, appending a line to a role's `SKILL.md` makes `build-personas.sh --check` exit 1.
  - With `GRID_PRIVATE_ROLES_DIR` set to a temp dir holding a role named `zz-private`, no `zz-private.md` is produced.
- [ ] 8.7 Add a pointer line to `docs/harnesses.md`: "Single-file personas for chat-UI Projects: `dist/personas/<role>.md`". README wording belongs to `front-door`.
- Verify: `bash scripts/gate.sh`.

## 9. HUMAN: smoke test on real harnesses

Depends on: 1, 3, 4, 6, 7. Group 5 is optional. Needs the harnesses installed and signed in.

- [ ] 9.1 Codex: add `harness:codex` to this machine's overlay, compose `--target codex` for the wired projects, and run `wire.sh`. Confirm all of the following:
  - A session starts without a skills error.
  - A wired skill carrying `allowed-tools`, `triggers` and `version` frontmatter is listed.
  - The count of skills Codex lists matches the count of links in `~/.agents/skills` (records the 8,000-char cap's effect).
  - `grid-qa-engineer` spawns from a symlinked `~/.codex/agents/*.toml` and cannot write files.
- [ ] 9.2 OpenCode: confirm that the `permission` mapping loads and that a symlinked agent file is found. Record whether a skill present in both `~/.claude/skills` and `~/.agents/skills` is listed twice.
- [ ] 9.3 Pi and OpenClaw: confirm that shared-dir skills load (Pi `/skill:<name>`; OpenClaw symlink rule). Create an empty `~/.codex/AGENTS.md` with one `rules:` pack wired, and confirm that Codex reads the block.
- [ ] 9.4 Optional, Gemini CLI or Antigravity: confirm the `tools` YAML list and a symlinked agent file on Gemini CLI. On `agy`, confirm the real global skills path.
- [ ] 9.5 Record each result with its date in a "Verified on a real install" table in `docs/harnesses.md`. Open a follow-up issue for any failure (stripped-copy skills, copy-with-marker agents, path correction). Close #3 and #30 as superseded and #35 as skipped (D11), linking this change.
- Verify: none automated. The PR is the updated table.
