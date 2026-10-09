## Context

the-grid wires skills and composed agents into `~/.claude/` only. `wire.sh` tears down every grid-owned symlink in `SKILLS_DIR` and `AGENTS_DIR` and rebuilds the wired set. `compose.py` has four targets (`claude-code`, `openclaw`, `openclaw-native`, `paperclip`).

The remit is every harness. This change adds Codex CLI, Gemini CLI, OpenCode, Pi and OpenClaw. Cursor comes along free (see below).

Two prior approaches were studied (read-only references):

- gstack `hosts/*.ts`: a declarative per-host config (paths, frontmatter allowlist, path rewrites) feeding a generator. Good model for a registry; its path rewriting is out of scope here.
- ECC `scripts/lib/install-targets/*.js`: 15 path-mapper adapters, mostly 10-50 LOC. The mirrors it maps (`.codex`, `.cursor`, `.opencode`, `.agents`) are hand-ported and have no parity check, so they cover 11-50% of source and drift. Lesson: one source, every copy generated, a test that fails on drift.

### Verified vendor facts (fetched 2026-10-09)

| Harness | Skills (user scope) | Subagents | Global instructions | Sources |
|---|---|---|---|---|
| Codex CLI | `~/.agents/skills` (also repo `.agents/skills`, admin `/etc/codex/skills`). Symlinked skill folders are followed. `~/.codex/skills` is NOT documented (on this Mac it holds only `.system`). Skills list capped at 2% of context or 8,000 chars. | `~/.codex/agents/*.toml`; required `name`, `description`, `developer_instructions`; optional `model`, `model_reasoning_effort`, `sandbox_mode`, `mcp_servers`, `skills.config`. `name` field is the identity, not the filename. | `~/.codex/AGENTS.md` (or `AGENTS.override.md`); project docs capped by `project_doc_max_bytes` = 32 KiB | learn.chatgpt.com/docs/build-skills, /docs/agent-configuration/subagents, /docs/agent-configuration/agents-md (developers.openai.com/codex/* redirects there) |
| Gemini CLI | `~/.gemini/skills/` or alias `~/.agents/skills/`; `.agents` wins over `.gemini`. Symlinks not mentioned. | `~/.gemini/agents/*.md`; frontmatter `name` (lowercase, digits, `-`, `_`), `description`, optional `tools`, `model` (default `inherit`), `temperature`, `max_turns`, `timeout_mins`, `kind`, `mcpServers`. Subagents cannot call subagents. On by default. | `~/.gemini/GEMINI.md`; `@file.md` imports; `context.fileName` can add `AGENTS.md` | geminicli.com/docs/cli/skills/, /docs/cli/creating-skills/, /docs/core/subagents/, /docs/cli/gemini-md/, /docs/reference/tools |
| Antigravity CLI (`agy`, Gemini CLI's successor for individual-tier users since 2026-06-18) | global `~/.gemini/antigravity-cli/skills/`; workspace `.agents/skills/` | location undocumented | reads workspace `GEMINI.md` and `AGENTS.md`; global `~/.gemini/GEMINI.md`; global AGENTS.md undocumented | developers.googleblog.com/an-important-update-transitioning-gemini-cli-to-antigravity-cli/, antigravity.google/docs/cli/gcli-migration. Third-party sources disagree on `~/.antigravity` vs `~/.gemini`: unverified. |
| OpenCode | `~/.config/opencode/skills/<n>/SKILL.md`; also reads `~/.agents/skills` and `~/.claude/skills` (disable Claude ones with `OPENCODE_DISABLE_CLAUDE_CODE_SKILLS=1`). Frontmatter: `name` (regex `^[a-z0-9]+(-[a-z0-9]+)*$`, must equal dir), `description` 1-1024; unknown fields ignored. | `~/.config/opencode/agents/<name>.md`; frontmatter `description` (required), `mode` (`primary`/`subagent`/`all`), `model` (`provider/model-id`), `temperature`, `permission` (`edit`, `bash`, `webfetch`, `task`: `ask`/`allow`/`deny`); body = system prompt; filename = agent id. `tools` is deprecated. | `~/.config/opencode/AGENTS.md`, falling back to `~/.claude/CLAUDE.md`; `instructions` array in `opencode.json` takes paths/globs/URLs | opencode.ai/docs/skills/, /docs/agents/, /docs/rules/ |
| Pi | `~/.agents/skills/` and `.agents/skills/` (walks up to repo root); recursive discovery; `skills` array in settings.json for extra paths; frontmatter `name`, `description` (<=1024), optional `license`, `compatibility`, `metadata`, `allowed-tools`, `disable-model-invocation`. First name wins, warning on collision. | none: "skips features like sub-agents" | `~/.pi/agent/AGENTS.md` (falls back to `CLAUDE.md`), parent dirs, cwd; config dir `PI_CODING_AGENT_DIR` | github.com/badlogic/pi-mono (packages/coding-agent docs/skills.md, docs/settings.md, README), unpkg mirror of docs/usage.md v0.73.1 for context files |
| OpenClaw | `~/.agents/skills` ("personal agent skills, default state only", priority 3), `<workspace>/skills`, `<workspace>/.agents/skills`, `~/.openclaw/skills`. Symlinked folders allowed in personal and managed roots if every `SKILL.md` realpath stays inside its resolved skill directory. Recursive to 6 levels. Per-agent allowlists in `openclaw.json`. | agents are workspaces: `agents.entries.<id>.workspace` | workspace `AGENTS.md`, `SOUL.md`, `USER.md`, `IDENTITY.md`, `MEMORY.md` (the existing `openclaw-native` target) | docs.openclaw.ai/tools/skills, /concepts/agent-workspace |
| Cursor (not a target) | `~/.agents/skills`, `~/.cursor/skills`; also reads `~/.claude/skills` and `~/.codex/skills`. `name` must equal folder. | not verified | n/a | cursor.com/docs/context/skills |

Agent Skills spec (agentskills.io/specification): `name` <=64 chars, lowercase/digits/hyphens, equals parent dir; `description` 1-1024; optional `license`, `compatibility` (<=500), `metadata` (string map), `allowed-tools` (experimental). The spec does not say whether unknown fields are ignored. OpenCode says it ignores them; Codex and Gemini docs are silent.

Local state on the drafting Mac (2026-10-09): `codex` is installed (`~/.codex/skills` holds only `.system`); no `pi`, `gemini`, `opencode`, `agy` or `openclaw` binary is on PATH, though leftover `~/.pi/agent/extensions`, `~/.gemini/{config,settings.json}` and `~/.config/opencode/plugins` exist. So only Codex can be smoke-tested here, and no local Pi agent exists to wire into.

Findings that shape the design:

- Five of six harnesses (Codex, Gemini CLI, OpenCode, Pi, OpenClaw) plus Cursor read `~/.agents/skills`. One directory reaches all of them.
- Codex does not read `~/.claude/skills`; Cursor and OpenCode do. A skill linked into both `~/.claude/skills` and `~/.agents/skills` may be listed twice in those two. Not verified.
- Measured on this Mac (167 wired skills): 55 reference `~/.claude` or `.claude/` in their files (45 are gstack); 1 has a description over 1024 chars (`claude-api`, 1068); 1 has `name` != directory (`template`). Claude-only extras in frontmatter: `triggers` 49, `version` 45, `preamble-tier` 40, `allowed-tools` 60, `hooks` 4, `argument-hint` 6.
- Only Pi has no subagents. OpenCode, Gemini CLI and Codex each have a file format for them.
- A skill is a universal "become this persona" carrier. The existing composed orchestrator is already a `SKILL.md` containing the persona, so orchestrators need no per-harness emitter.

## Approach

Two layers, both generated, nothing hand-copied:

1. Skills and rules: link or place existing generated artefacts. `wire.sh` reads a registry and fans out.
2. Agents: `compose.py` renders specialists for the harnesses that have a subagent file. Orchestrators ride layer 1 as skills.

### Registry: `scripts/lib/harnesses.tsv`

Tab-separated, `#` comments, `~` expands to `${GRID_HARNESS_HOME:-$HOME}`. One row per harness. `-` means "this harness has none".

```
# harness    skills_dir                       agents_dir                   compose_target  rules_file                     rules_mode
claude       ~/.claude/skills                 ~/.claude/agents             claude-code     -                              -
codex        ~/.agents/skills                 ~/.codex/agents              -               ~/.codex/AGENTS.md             block
gemini       ~/.agents/skills                 ~/.gemini/agents             -               ~/.gemini/GEMINI.md            block
antigravity  ~/.gemini/antigravity-cli/skills -                            -               ~/.gemini/GEMINI.md            block
opencode     ~/.agents/skills                 ~/.config/opencode/agents    -               ~/.config/opencode/AGENTS.md   block
pi           ~/.agents/skills                 -                            -               ~/.pi/agent/AGENTS.md          block
openclaw     ~/.agents/skills                 -                            -               -                              -
```

`compose_target` ships as `-` for codex, gemini and opencode and is flipped by each emitter's own task group (`codex`, `gemini-cli`, `opencode`). `claude` keeps `SKILLS_DIR` / `AGENTS_DIR` env overrides exactly as today; every other row is redirected by `GRID_HARNESS_HOME` in tests. Rows sharing a `skills_dir` are linked once.

### Manifest and flags

`baseline-submodules.txt` / `machines/<host>.txt` gain:

```
harness:codex        # activate a harness on this machine
-harness:codex       # deactivate one the baseline activated
```

Resolution order: `--harness a,b` flag, else `GRID_HARNESS` env, else the union of manifest entries, else `claude` alone. `claude` is active unless explicitly subtracted. Unknown names fail with exit 2 and list the registry.

`wire.sh` flow after this change:

1. Tear down grid-owned symlinks (target under `GRID_DIR`) in every registry dir, active or not.
2. Existing steps 2-3c run unchanged and record each wired skill name and dir in an in-memory list.
3. New step 3e: for each active non-claude harness, link every listed skill that passes the portability filter into its `skills_dir`, then link `projects/*/_<compose_target>/agents/*` (gated by `project:<name>` as today) into its `agents_dir`.
4. `.wired.manifest` rows for non-claude dirs use kind `skill@<dir>` / `agent@<dir>` with `<dir>` in `~/` form; skips carry a reason column. Claude rows are unchanged.
5. `--check` runs the whole thing into a throwaway home and diffs every registry dir, not just the two Claude dirs.

### Portability filter: `scripts/lib/skill-portable.sh`

`skill_portable <skill_dir>` prints nothing and exits 0, or prints a reason and exits 1. Applied only to non-claude harnesses. Reasons, checked in this order:

- `no-frontmatter`: `SKILL.md` lacks a leading `---` block.
- `name-mismatch`: frontmatter `name` differs from the directory basename. (The symlink basename is what harnesses see; the skill dir name is the link name.)
- `name-invalid`: link name fails `^[a-z0-9]+(-[a-z0-9]+)*$` or is over 64 chars.
- `description-long`: description over 1024 chars after YAML folding.
- `claude-specific`: any file under the skill dir matches `~/\.claude|\.claude/|CLAUDE_|\$HOME/\.claude` (text files only, under 1 MB each).

Frontmatter is parsed with a 20-line stdlib Python helper (`scripts/lib/skill_frontmatter.py`, `python3 -I`), not PyYAML, so it runs where the agent-factory venv is absent. It supports single-line, quoted, and `>`/`|` block scalars, which are the shapes present in the wired set.

### Agent formats emitted

Specialists only. All three share one body: the existing full-profile subagent body, extracted from `emit_cc_subagent` into `render_subagent_body(agent, slug, project_context)` so Claude output stays byte-identical.

Codex (`_codex/agents/<slug>-<role>.toml`):

```toml
name = "grid-qa-engineer"
description = "QA Engineer. The release gate. ... Use this subagent for qa-engineer work."
sandbox_mode = "read-only"
developer_instructions = """
You are the **QA Engineer**, a specialist agent on a composed dev team. ...
"""
```

- `model` is never written.
- `sandbox_mode = "read-only"` is written only when `role.yaml tools:` exists and contains neither `Edit` nor `Write`. Consequence: those roles cannot write via Bash either; this is deliberate (safer than CC's Bash-can-write).
- TOML strings are hand-written (no writer in stdlib): escape `\` as `\\` and `"""` as `\"\"\"`, drop control characters other than `\n` and `\t`. Output must round-trip through `tomllib`.

Gemini CLI (`_gemini-cli/agents/<slug>-<role>.md`):

```markdown
---
name: grid-qa-engineer
description: QA Engineer. The release gate. ... Use this subagent for qa-engineer work.
tools:
- read_file
- read_many_files
- grep_search
- glob
- list_directory
- run_shell_command
---
You are the **QA Engineer**, ...
```

- `model` is never written (default `inherit`).
- `tools` is written only when the role has an allowlist. Mapping from Claude tool names: `Read` to `read_file`, `read_many_files`; `Grep` to `grep_search`; `Glob` to `glob`, `list_directory`; `Bash` to `run_shell_command`; `Edit` to `replace`; `Write` to `write_file`; `WebFetch` to `web_fetch`; `WebSearch` to `google_web_search`. An unmapped tool name is a compose error `E_TOOL_UNMAPPED` naming role and tool (fail closed).

OpenCode (`_opencode/agents/<slug>-<role>.md`):

```markdown
---
description: QA Engineer. The release gate. ... Use this subagent for qa-engineer work.
mode: subagent
permission:
  edit: deny
  webfetch: deny
---
You are the **QA Engineer**, ...
```

- `model` is never written.
- `permission` is written only when the role has an allowlist: `edit: deny` if neither `Edit` nor `Write` listed; `bash: deny` if `Bash` absent; `webfetch: deny` if neither `WebFetch` nor `WebSearch` listed. Absent keys inherit.

Orchestrators (roles with `orchestrator: true`) are not written by these three targets. They are the `SKILL.md` folders already produced under `_claude-code/skills/`, wired into the shared skills directory by step 3e. Names match across harnesses (`grid-tech-lead` is the same skill and the same subagent name everywhere), so the roster tables in orchestrator bodies stay correct.

Root-owned `agents/*.md` (hand-authored Claude subagents such as `grid-ponytail`) are Claude-only: no generated source exists to render them per harness.

### Rules delivery

Workstream 8 (`rule-packs`) compiles rules per harness. This change only places the result. Interface: WS8 emits one file per harness at `$GRID_DIR/dist/rules/<harness>.md` containing only the packs selected for this machine. `RULES_DIST` is a single constant in `scripts/lib/harness.sh`; if WS8 lands a different path, that constant is the only edit.

Placement (`rules_mode=block`): a managed block inside the harness's global instruction file.

```markdown
<!-- grid:rules begin sha256=<hex> -->
...content of dist/rules/<harness>.md...
<!-- grid:rules end -->
```

- File absent: create it with only the block. Markers present: replace between them. Markers absent: append a blank line then the block. Text outside the markers is never touched.
- Block unchanged (same sha) means no write, so a second run is a no-op.
- Deactivating a harness removes its block (and deletes the file only if it is then empty).
- Cap: `GRID_RULES_MAX_BYTES` default 8192 per block. Over the cap is an error, nothing is written. Codex shares a 32 KiB limit across all instruction files in a session.
- Opt-in: no `dist/rules/<harness>.md`, no block. Nothing is injected by default.

### Conformance

Three kinds of test, none touching a real home:

- Goldens (#23): fixture roles in `tests/fixtures/harness/roles/` (one specialist with a tools allowlist, one without, one orchestrator with `delegates_to`), a fixture config, `GRID_PRIVATE_ROLES_DIR` pointing at the fixture roles, `GRID_MODELS_FILE` and the new `GRID_USER_CONFIG` pointing at fixtures. Expected trees live in `tests/golden/<target>/`. Byte-compared. `GRID_UPDATE_GOLDEN=1` rewrites them; the bats test fails if it is set in CI (`CI` env present).
- Format validators (`tests/lib/validate_harness.py`, stdlib only): Codex TOML parses and has the three required keys; Gemini frontmatter has `name` matching `^[a-z0-9_-]+$` and `description`; OpenCode frontmatter has `description` and `mode: subagent`; every shared-dir skill passes Agent Skills constraints. These encode the verified vendor facts above, so a vendor-doc change means editing one file.
- Wiring tests: temp `GRID_DIR`, `GRID_HARNESS_HOME`, `SKILLS_DIR`, `AGENTS_DIR`; the `assert_sandboxed` helper is extended to refuse `GRID_HARNESS_HOME` equal to the real home.

### Portable personas (#36)

`compose.py --target portable` writes `<out>/personas/<role>.md`: `# <Title>` then the shared subagent body with an empty slug. No frontmatter, no tool fields. `scripts/build-personas.sh` wipes `dist/personas/`, composes the four public configs (`core`, `grid`, `finance-desk`, `learning-desk`) with `GRID_PRIVATE_ROLES_DIR=` (empty) and `GRID_USER_CONFIG=agent-factory/user.public.yaml`, and `--check` diffs. The generated bodies embed the IDENTITY nameplate, which today reads the local `user.yaml` and falls back to the hostname; the fixed public user file prevents any personal value reaching a committed file. The gate runs `build-personas.sh --check` when the venv exists.

## Decisions

- Decided: one shared skills directory (`~/.agents/skills`) serves Codex, Gemini CLI, OpenCode, Pi and OpenClaw. Reason: five vendor docs name it; per-harness copies would only add drift.
- Decided: skills are symlinked as-is, with no frontmatter stripping or copying. Reason: all targets read the same format and symlinks are documented for Codex and OpenClaw; the HUMAN smoke test (group 10) checks extra Claude-only fields on Codex, and a stripped-copy fallback is a follow-up only if it fails.
- Decided: Claude-specific skills are skipped for non-Claude harnesses, not rewritten. Reason: gstack-style path rewriting needs a TS build and per-skill review; skipping is honest and reversible.
- Decided: skipping is automatic and recorded; there is no per-skill override in this change. Reason: smallest design; a skill with a legitimate claim to portability fixes its own text.
- Decided: harnesses are opt-in per machine; the default stays `claude` only. Reason: no behaviour change on existing machines, and nothing writes into `~/.codex` unasked.
- Decided: registry is a TSV parsed with `awk`, not YAML. Reason: wire.sh is bash and must not need PyYAML.
- Decided: the registry's `claude` row keeps `SKILLS_DIR` / `AGENTS_DIR` overrides; all other rows use `GRID_HARNESS_HOME`. Reason: existing tests and docs keep working unchanged.
- Decided: Gemini CLI and Antigravity are separate registry rows. Reason: their global skills paths differ and Google moved individual-tier users to Antigravity on 2026-06-18; Gareth may be on either.
- Decided: Antigravity gets skills and rules only; no agent emitter. Reason: its subagent location is undocumented.
- Decided: orchestrators ship as skills on every harness; no `mode: primary`, no `GEMINI.md` folding, no Codex `[agents]` config. Reason: one rule across harnesses, no second orchestrator shape, resolves the open design calls in #32 and #33.
- Decided: `model` is never written into non-Claude agents. Reason: model ids are provider-specific and rot (see `docs/model-selection.md`); inheriting the session model is always valid.
- Decided: tool allowlists map to Codex `sandbox_mode`, Gemini `tools` and OpenCode `permission`; an unmapped tool is a compose error. Reason: read-only roles (qa, security) must stay read-only everywhere.
- Decided: agent files are symlinked into each harness's agents dir like Claude's. Reason: same ownership and teardown model; symlink support for agent files is unverified, so the smoke test covers it and a copy-with-marker fallback is a follow-up.
- Decided: `compose_target` flips from `-` per emitter group. Reason: groups 3-5 stay independently mergeable and `compose-harnesses.sh` never calls a target that does not exist yet.
- Decided: `scripts/compose-harnesses.sh` composes `claude-code` plus each active harness's `compose_target` for the public configs; `wire.sh` never runs `compose.py`. Reason: wire.sh stays fast, offline and venv-free.
- Decided: rules are placed as a managed block, capped at 8192 bytes, and only when WS8's `dist/rules/<harness>.md` exists. Reason: user-owned files, shared Codex byte cap, and the token-cost rule (opt-in, budgeted).
- Decided: `compose.py` gets a `GRID_USER_CONFIG` env override. Reason: goldens and committed personas must not depend on the machine's `user.yaml` or hostname.
- Decided: `dist/personas/` is regenerated by an explicit script and guarded by a gate check, not rewritten as a side effect of every `compose.py` run. Reason: deviates from #36's "always regenerate" because a hidden write on unrelated targets breaks the idempotent per-target contract; the gate catches staleness, and the script is one command.
- Decided: goldens are fixture-based, not over real roles. Reason: role edits would otherwise churn every golden.
- Decided: Pi gets no emitter and no agents dir. Reason: Pi documents no sub-agents.
- Decided: OpenClaw reuses the existing `openclaw-native` target; this change adds goldens for it and skills reach only. Reason: renderer exists; live deploy is governed by the throwaway-agent rule, not by this change.
- Decided: Cursor is not a harness row. Reason: not in the remit list; it already reads the shared directory.
- Decided: Gemini `tools` is written as a YAML block list. Reason: the docs say "tool names" and do not show the syntax; a list is the YAML-natural form and the smoke test confirms it.
- Decided: group 10 (real-harness smoke test) is `HUMAN:`. Reason: needs installed harnesses and accounts; Codex is installed on this Mac, the rest are not.

## Issue dispositions

- #3 (OpenClaw emitter): superseded. Renderer exists; this change adds goldens and skills reach. Live deploy stays with `deploy_openclaw.sh`.
- #23 (golden outputs): folded into group 2.
- #30 (Cursor reuse of `.claude/agents`): superseded; Cursor reads the shared skills directory with no work. Agent reuse is an optional line in the group 10 smoke test.
- #31, #32, #33 (opencode, Gemini, Codex targets): groups 5, 4, 3. The orchestrator design calls in #32 and #33 are resolved above.
- #34 (Amp): stays deferred; Non-goal.
- #35 (Continue): close as skipped; Non-goal.
- #36 (portable personas): group 9, with the gate-instead-of-side-effect deviation above.

## Risks

- Extra Claude-only frontmatter fields (`triggers`, `preamble-tier`, `hooks`) may be rejected by Codex or Gemini. gstack's Codex host allowlists `name` and `description` only, which hints at caution. Mitigation: group 10 tests it; fallback is emitting stripped copies.
- Duplicate listing in OpenCode and Cursor (they read both `~/.claude/skills` and `~/.agents/skills`). Mitigation: documented env switch for OpenCode; group 10 records actual behaviour.
- Vendor drift. Mitigation: the verified-facts table lives in `docs/harnesses.md` with a date; validators encode it.
- Antigravity global path conflict between sources. Mitigation: HUMAN check in group 10 before trusting the row.

## Open questions

- Which Gemini does Gareth use (Gemini CLI with a paid key, or Antigravity)? Decides which row is worth smoke-testing.
- Does WS8 emit `dist/rules/<harness>.md`? If not, edit `RULES_DIST`.
- Should orchestrators also appear as OpenCode `mode: primary` agents? Not done; say so if wanted.
