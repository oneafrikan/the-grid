## Context

the-grid wires skills and composed agents into `~/.claude/` only. Each run, `wire.sh` tears down every grid-owned symlink in `SKILLS_DIR` and `AGENTS_DIR` and rebuilds the wired set. `compose.py` has four targets: `claude-code`, `openclaw`, `openclaw-native` and `paperclip`. Each writer wipes and rewrites only its own `<out>/<project>/_<target>/` dir. The exception is the legacy `openclaw`, which rewrites the whole project dir.

The remit is every harness. This change adds Codex CLI, OpenCode, Gemini CLI, Pi and OpenClaw. Cursor comes along at no extra cost.

Two earlier approaches were studied as read-only references:

- gstack `hosts/*.ts`: a declarative per-host config (paths, frontmatter allowlist, path rewrites) that feeds a generator. It is a good model for a registry. Its path rewriting is out of scope here.
- ECC `scripts/lib/install-targets/*.js`: 15 path-mapper adapters. The mirrors they map are hand-ported and have no parity check, so they cover only 11-50% of the source. Lesson: keep one source, generate every copy, and add a test that fails on drift.

### Verified vendor facts (fetched 2026-10-09)


| Harness | Skills (user scope) | Subagents | Global instructions | Sources |
|---|---|---|---|---|
| Codex CLI | `~/.agents/skills` (also repo `.agents/skills`, admin `/etc/codex/skills`). Symlinked skill folders are followed. `~/.codex/skills` is NOT documented (on the drafting machine it holds only `.system`). Skills list capped at 2% of context or 8,000 chars. | `~/.codex/agents/*.toml`; required `name`, `description`, `developer_instructions`; optional `model`, `model_reasoning_effort`, `sandbox_mode`, `mcp_servers`, `skills.config`. `name` field is the identity, not the filename. | `~/.codex/AGENTS.md` (or `AGENTS.override.md`); project docs capped by `project_doc_max_bytes` = 32 KiB | learn.chatgpt.com/docs/build-skills, /docs/agent-configuration/subagents, /docs/agent-configuration/agents-md (developers.openai.com/codex/* redirects there) |
| Gemini CLI | `~/.gemini/skills/` or alias `~/.agents/skills/`; `.agents` wins over `.gemini`. Symlinks not mentioned. | `~/.gemini/agents/*.md`; frontmatter `name` (lowercase, digits, `-`, `_`), `description`, optional `tools`, `model` (default `inherit`), `temperature`, `max_turns`, `timeout_mins`, `kind`, `mcpServers`. Subagents cannot call subagents. On by default. | `~/.gemini/GEMINI.md`; `@file.md` imports; `context.fileName` can add `AGENTS.md` | geminicli.com/docs/cli/skills/, /docs/cli/creating-skills/, /docs/core/subagents/, /docs/cli/gemini-md/, /docs/reference/tools |
| Antigravity CLI (`agy`, Gemini CLI's successor for individual-tier users since 2026-06-18) | global `~/.gemini/antigravity-cli/skills/`; workspace `.agents/skills/` | location undocumented | reads workspace `GEMINI.md` and `AGENTS.md`; global `~/.gemini/GEMINI.md`; global AGENTS.md undocumented | developers.googleblog.com/an-important-update-transitioning-gemini-cli-to-antigravity-cli/, antigravity.google/docs/cli/gcli-migration. Third-party sources disagree on `~/.antigravity` vs `~/.gemini`: unverified. |
| OpenCode | `~/.config/opencode/skills/<n>/SKILL.md`; also reads `~/.agents/skills` and `~/.claude/skills` (disable Claude ones with `OPENCODE_DISABLE_CLAUDE_CODE_SKILLS=1`). Frontmatter: `name` (regex `^[a-z0-9]+(-[a-z0-9]+)*$`, must equal dir), `description` 1-1024; unknown fields ignored. | `~/.config/opencode/agents/<name>.md`; frontmatter `description` (required), `mode` (`primary`/`subagent`/`all`), `model` (`provider/model-id`), `temperature`, `permission` (`edit`, `bash`, `webfetch`, `task`: `ask`/`allow`/`deny`); body = system prompt; filename = agent id. `tools` is deprecated. | `~/.config/opencode/AGENTS.md`, falling back to `~/.claude/CLAUDE.md`; `instructions` array in `opencode.json` takes paths/globs/URLs | opencode.ai/docs/skills/, /docs/agents/, /docs/rules/ |
| Pi | `~/.agents/skills/` and `.agents/skills/` (walks up to repo root); recursive discovery; `skills` array in settings.json for extra paths; frontmatter `name`, `description` (<=1024), optional `license`, `compatibility`, `metadata`, `allowed-tools`, `disable-model-invocation`. First name wins, warning on collision. | none: "skips features like sub-agents" | `~/.pi/agent/AGENTS.md` (falls back to `CLAUDE.md`), parent dirs, cwd; config dir `PI_CODING_AGENT_DIR` | github.com/badlogic/pi-mono (packages/coding-agent docs/skills.md, docs/settings.md, README), unpkg mirror of docs/usage.md v0.73.1 for context files |
| OpenClaw | `~/.agents/skills` ("personal agent skills, default state only", priority 3), `<workspace>/skills`, `<workspace>/.agents/skills`, `~/.openclaw/skills`. Symlinked folders allowed in personal and managed roots if every `SKILL.md` realpath stays inside its resolved skill directory. Recursive to 6 levels. Per-agent allowlists in `openclaw.json`. | agents are workspaces: `agents.entries.<id>.workspace` | workspace `AGENTS.md`, `SOUL.md`, `USER.md`, `IDENTITY.md`, `MEMORY.md` (the existing `openclaw-native` target) | docs.openclaw.ai/tools/skills, /concepts/agent-workspace |

Agent Skills spec (agentskills.io/specification): `name` <=64 chars, lowercase/digits/hyphens, equal to the parent dir; `description` 1-1024; optional `license`, `compatibility` (<=500), `metadata` (string map), `allowed-tools` (experimental). The spec does not say whether unknown fields are ignored. OpenCode says it ignores them. The Codex and Gemini docs are silent.

On the drafting machine (2026-10-09), only `codex` was installed, so only Codex can be smoke-tested there.

### Findings that shape the design

- **One shared skills directory reaches five harnesses.** Codex, Gemini CLI, OpenCode, Pi and OpenClaw all read `~/.agents/skills`, and Cursor does too. Linking the wired set there once covers every target, so no per-harness skill copies are needed.
- Activation is per directory, not per harness. Activating any shared-dir harness puts the skills in front of every installed harness that reads `~/.agents/skills`.
- OpenCode and Cursor also read `~/.claude/skills`, so a skill in both dirs may be listed twice there (not verified). OpenCode has a documented switch to turn off its Claude read: `OPENCODE_DISABLE_CLAUDE_CODE_SKILLS=1`.
- Codex caps its skill listing at 2% of context or 8,000 chars. Past that, descriptions are dropped. `budget-and-usage` shortens descriptions, but a large wired set will still overflow on Codex.
- Measured over 167 wired skills: 55 reference `~/.claude` or `.claude/` (45 of them gstack), 1 has a description over 1024 chars (`claude-api`, 1068), and 1 has `name` != dir (`template`). Claude-only frontmatter fields appear in many of them: `triggers` 49, `version` 45, `preamble-tier` 40, `allowed-tools` 60, `hooks` 4, `argument-hint` 6.
- Only Pi has no subagents. Codex, OpenCode and Gemini CLI each have a subagent file format.
- A composed orchestrator is already a `SKILL.md` that carries the persona. Orchestrators therefore need no per-harness emitter.
- OpenCode falls back to `~/.claude/CLAUDE.md` when `~/.config/opencode/AGENTS.md` is absent, and Pi does the same. Creating those files would silently turn off that fallback.

## Approach

There are two layers. Both are generated, and nothing is hand-copied.

1. Skills and rules: `wire.sh` reads a registry and fans out links (skills) or calls `rules.py emit` (rules).
2. Agents: `compose.py` renders specialists for the harnesses that have a subagent format. Orchestrators ride layer 1 as skills.

### Registry: `scripts/lib/harnesses.tsv`

The file is tab-separated with `#` comments. `~` expands to `${GRID_HARNESS_HOME:-$HOME}`, and `-` means the harness has none of that thing. The `claude` row is listed for reference only: wire.sh keeps using `SKILLS_DIR` / `AGENTS_DIR` for Claude exactly as today.

```
# harness    skills_dir                       agents_dir                  compose_target  rules_file                    rules_harness
claude       ~/.claude/skills                 ~/.claude/agents            claude-code     -                             -
codex        ~/.agents/skills                 ~/.codex/agents             codex           ~/.codex/AGENTS.md            agents-md
opencode     ~/.agents/skills                 ~/.config/opencode/agents   opencode        ~/.config/opencode/AGENTS.md  agents-md
gemini       ~/.agents/skills                 ~/.gemini/agents            gemini-cli      ~/.gemini/GEMINI.md           gemini
antigravity  ~/.gemini/antigravity-cli/skills -                           -               -                             -
pi           ~/.agents/skills                 -                           -               ~/.pi/agent/AGENTS.md         agents-md
openclaw     ~/.agents/skills                 -                           -               -                             -
```

`compose_target` is filled in from the start. wire.sh links `agent-factory/projects/<p>/_<compose_target>/agents/*` only if that dir exists, so an emitter that has not landed yet simply links nothing. `rules_harness` is the value passed to `rules.py emit --harness` (the `rule-packs` interface).

### Active set

- Manifest grammar, in `baseline-submodules.txt` / `machines/<host>.txt` / `.local.txt`: `harness:<name>` activates a harness and `-harness:<name>` subtracts one. Both cases go in `load_manifest` before the generic `-*` / `*` cases.
- `GRID_HARNESS=a,b`, when non-empty, replaces the manifest set for one run.
- `claude` is always active and cannot be subtracted. `harness:claude` is accepted and does nothing.
- An unknown name, from the manifest or the env, makes wire.sh exit 2 before any write and list the registry names.

### wire.sh flow after this change

1. Tear down grid-owned symlinks (target under `GRID_DIR`) in `SKILLS_DIR`, `AGENTS_DIR`, and every non-claude registry `skills_dir` / `agents_dir`, active or not. Missing dirs are ignored.
2. Steps 2 to 3c run unchanged.
3. New step 3e: for each distinct `skills_dir` of the active non-claude harnesses, take every grid-owned symlink now in `SKILLS_DIR`, in sorted order. Precedence and dedupe are therefore exactly Claude's. Run `skill_portable` on its target and link it under the same name if the check passes. Otherwise record a skip. For each active harness with an `agents_dir` and `compose_target`, link `projects/<p>/_<compose_target>/agents/*` for projects where `project_is_wired`. Both use the existing "real dir/file, not managed" skip.
4. New step 3f, rules: see Rules delivery below.
5. `.wired.manifest` rows for non-claude dirs use kind `skill@<dir>` / `agent@<dir>`, where `<dir>` is in `~/` form so the file is home-independent. Skip rows carry the reason. Claude rows are unchanged.
6. `--check` additionally sets `GRID_HARNESS_HOME=$tmp/home` for the throwaway run. It diffs grid-owned links in every distinct non-claude registry dir, with the live dir under `${GRID_HARNESS_HOME:-$HOME}` and the same shadow filter as today. It also runs the rules `--check` (below).

### Portability filter

`scripts/lib/skill-portable.sh` defines `skill_portable <skill_dir>`. It prints nothing and returns 0 when the skill passes. Otherwise it prints a reason and returns 1. The filter applies only to non-claude dirs. Reasons, checked in order:

- `no-frontmatter`: `SKILL.md` does not start with a `---` block.
- `name-mismatch`: frontmatter `name` differs from the link name (the dir basename).
- `name-invalid`: the link name fails `^[a-z0-9]+(-[a-z0-9]+)*$` or is over 64 chars.
- `description-long`: the description is over 1024 chars after YAML folding.
- `claude-specific`: `grep -rqIE '~/\.claude|\$HOME/\.claude|\.claude/|CLAUDE_' <skill_dir>` matches (`-I` skips binaries).

`scripts/lib/skill_frontmatter.py` reads frontmatter with the stdlib only and runs as `python3 -I`. It handles plain, quoted and `>`/`|` block scalars, and prints `name<TAB>description` with the description's newlines folded to spaces.

### Agent formats emitted

These are for specialists only. All three targets share one body. `compose.py` gains `render_subagent_body(agent, slug)`, which is the full-profile body extracted verbatim from `emit_cc_subagent`. `emit_cc_subagent` calls it, so Claude output stays byte-identical. A generic `write_harness_agents(target, name, config, out_dir)` handles writing. It refuses a symlinked dir, wipes `<out>/<name>/_<target>/`, and writes `agents/<file>` for each non-orchestrator role through a dispatch table `AGENT_TARGETS = {target: emit_fn}`. It is registered in `--target` choices, the `--check` writers and `--dry-run`. Wiping the dir is what prevents orphans.

The name and description are the same as the Claude subagent's: `slugged(agent_slug(agent, slug), role)` and `"<Title>. <summary> Use this subagent for <role> work."`. `model` is never written.

Codex (`_codex/agents/<name>.toml`):

```toml
name = "grid-qa-engineer"
description = "QA Engineer. The release gate. ... Use this subagent for qa-engineer work."
sandbox_mode = "read-only"
developer_instructions = """
You are the **QA Engineer**, a specialist agent on a composed dev team. ...
"""
```

- Key order is `name`, `description`, then `sandbox_mode` (only when the role has a `tools:` allowlist without `Edit` or `Write`), then `developer_instructions`.
- TOML strings are written by hand, since the stdlib has no TOML writer. Basic strings escape `\` and `"`. The multi-line basic string escapes `\` as `\\` and `"""` as `\"\"\"`, and drops control chars other than `\n` and `\t`. The output must round-trip through `tomllib`.

OpenCode (`_opencode/agents/<name>.md`, filename = agent id):

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

- `permission` is written only when the role has an allowlist. Its keys are `edit: deny` if neither `Edit` nor `Write` is listed, `bash: deny` if `Bash` is absent, and `webfetch: deny` if neither `WebFetch` nor `WebSearch` is listed. Keys are written in that order, and absent keys inherit.

Gemini CLI (`_gemini-cli/agents/<name>.md`):

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

- `tools` is written only when the role has an allowlist. It is mapped in the role's listed order, with duplicates dropped:
  - `Read` to `read_file`, `read_many_files`
  - `Grep` to `grep_search`
  - `Glob` to `glob`, `list_directory`
  - `Bash` to `run_shell_command`
  - `Edit` to `replace`
  - `Write` to `write_file`
  - `WebFetch` to `web_fetch`
  - `WebSearch` to `google_web_search`
- An unmapped tool is compose error `E_TOOL_UNMAPPED <role> <tool>`. Compose exits 1 and writes nothing, because the check runs before the wipe.

Description values in YAML frontmatter go through the existing `_frontmatter` helper, which already quotes for Claude output.

Orchestrators (`orchestrator: true`) are not written by these targets. They are the `_claude-code/skills/<name>/` folders, which step 3e links into the shared skills dir. Names match across harnesses, so roster tables stay correct. Root-owned `agents/*.md` are Claude-only because there is no role source to render them from.

Compose commands for a machine that runs other harnesses go in `docs/harnesses.md`, e.g. `compose.py examples/grid.yaml --target codex`. Each target writes only its own `_<target>/` dir, so recomposing one target never disturbs another or a private project.

### Rules delivery

`rule-packs` owns the rule format and the emitter. This change only calls it:

```
python3 scripts/rules.py emit --harness <rules_harness> --packs <p1,p2,...> --out <rules_file>
```

- `<packs>` is the wired rule set from `rule-packs#2` (`rules:<pack>` minus `-rules:<pack>`), comma-joined in C-locale order.
- The call is made for each active harness with a `rules_file`, and **only if that file already exists**. The operator opts in per harness by creating the file, even an empty one. wire.sh never creates a global instruction file. A missing file is recorded as a `rules@<file>` manifest row: `skipped`, reason `rules-file-absent`.
- Inactive harnesses whose existing file contains the `rule-packs` BEGIN marker get the same call with `--packs ''`. This removes the block, using the empty-selection behaviour of `rule-packs#4`.
- The marker format, size cap, idempotency and the guarantee that text outside the block stays byte-identical all belong to `rules.py`. A non-zero exit from `rules.py` is reported and makes wire.sh exit non-zero after it has finished every other step.
- `--check` runs the same calls with `--check` against the live files.
- No `rules:` entries means `--packs ''`, which means no block. Nothing is injected by default.

### Conformance

- Goldens reuse `workflow-upgrades#2`: `scripts/compose-goldens.sh` and the fixtures under `tests/fixtures/compose/`, run with `GRID_USER_CONFIG` pinned to the fixture `user.yaml`.
- This change adds one fixture role `fx-readonly` (`tools: [Read, Grep, Glob, Bash]`) to that fixture config, which also regenerates the `claude-code` golden in the same PR.
- Each emitter group adds its target name to `compose-goldens.sh`'s target list and commits its golden tree.
- Format validators live in `tests/lib/validate_harness.py` (stdlib only), with subcommands `codex-agent`, `opencode-agent`, `gemini-agent` and `skill`. They encode the vendor facts above, so a vendor-doc change means editing one file.
- Wiring tests use temp `GRID_DIR`, `SKILLS_DIR`, `AGENTS_DIR` and `GRID_HARNESS_HOME`. `assert_sandboxed` also refuses a `GRID_HARNESS_HOME` that resolves to the real home.

### Portable personas (#36)

- `compose.py --target portable` writes `<out>/<name>/_portable/<role>.md` for every role, orchestrators included. Each file is `# <Title>` followed by `render_lean_body(agent, "")`.
- The lean body has no IDENTITY nameplate, boot sequence or memory plumbing. It therefore carries no machine or operator values and needs no user-config override.
- `scripts/build-personas.sh` composes `agent-factory/examples/*.yaml` with `GRID_PRIVATE_ROLES_DIR=` (empty) into a temp dir. It copies every `_portable/*.md` into `dist/personas/`, with configs in C-locale order and later configs overwriting earlier ones, and removes files no longer produced.
- `--check` builds into a temp dir and runs `diff -r`. The gate runs `--check` when the venv exists and skips loudly otherwise.

## Decisions

- Decided: one shared skills dir (`~/.agents/skills`) serves Codex, OpenCode, Gemini CLI, Pi and OpenClaw. Reason: all five vendor docs name it, and per-harness copies would only add drift.
- Decided: the shared dir holds one skill set; there are no per-harness subsets. Reason: the dir is shared, so a subset per harness is not expressible without separate dirs.
- Decided: the non-Claude skill set is derived from the grid-owned links in `SKILLS_DIR` after step 3c. Reason: it inherits Claude's precedence (root wins) and dedupe for free, so a name is never linked twice.
- Decided: skills are symlinked as-is, with no frontmatter stripping. Reason: all targets read the same format and symlinks are documented for Codex and OpenClaw. The HUMAN smoke test checks extra Claude-only fields on Codex, and stripped copies are a follow-up only if that fails.
- Decided: Claude-specific skills are skipped for non-Claude harnesses, not rewritten, and there is no per-skill override. Reason: skipping is honest, reversible and the smallest design. A skill that should be portable fixes its own text.
- Decided: harnesses are opt-in per machine, and the default stays `claude` only. Reason: no behaviour change on existing machines, and nothing writes outside `~/.claude` unasked.
- Decided: `claude` is always active and cannot be subtracted. Reason: the non-Claude skill set is derived from `SKILLS_DIR`, and no use case for a Claude-less grid was named.
- Decided: `GRID_HARNESS` env var, no `--harness` flag. Reason: wire.sh parses only `--check` today, and an env var avoids an argument-parser rewrite.
- Decided: the registry is a TSV parsed with `awk`, not YAML. Reason: wire.sh is bash and must not need PyYAML.
- Decided: `compose_target` is set from the start, and wire.sh skips a missing `_<target>/` dir. Reason: emitter groups stay independently mergeable with no registry edits.
- Decided: Antigravity is skills-only (no agents dir, no rules file). Reason: operator answer. Its subagent location and global AGENTS.md are undocumented.
- Decided: Gemini CLI is lower priority than Codex and OpenCode. Its emitter group comes last, and its smoke test is optional. Reason: operator answer.
- Decided: orchestrators ship as skills on every harness: no OpenCode `mode: primary`, no `GEMINI.md` folding, no Codex `[agents]` config. Reason: operator answer, and one orchestrator shape resolves #32 and #33.
- Decided: `model` is never written into non-Claude agents. Reason: model ids are provider-specific and rot, while inheriting the session model is always valid.
- Decided: tool allowlists map to Codex `sandbox_mode`, OpenCode `permission` and Gemini `tools`, and an unmapped tool is a compose error. Reason: read-only roles (qa, security) must stay read-only everywhere.
- Decided: a Codex `read-only` sandbox also blocks writes through Bash. Reason: stricter than Claude's Bash-can-write, and it errs safe.
- Decided: agent files are symlinked into each harness's agents dir, as for Claude. Reason: same ownership and teardown model. Symlink support for agent files is unverified, so the smoke test covers it, and copy-with-marker is a follow-up.
- Decided: non-Claude subagents use the full-profile body, the same as Claude subagents. Reason: one body, one golden family, and no second rendering to drift.
- Decided: rules are delivered only into an instruction file that already exists, via `rules.py emit`. Reason: creating `~/.config/opencode/AGENTS.md` or `~/.pi/agent/AGENTS.md` would silently disable their fallback to `~/.claude/CLAUDE.md`. Requiring the file is also a second explicit opt-in for always-loaded tokens.
- Decided: no block logic, cap or marker format in this change. Reason: D2, `rule-packs` owns the emitter.
- Decided: goldens extend `workflow-upgrades#2`, and there is no second golden harness and no own `GRID_USER_CONFIG`. Reason: D1.
- Decided: personas use the lean body with an empty slug. Reason: a chat-UI Project has no boot sequence, memory files or signal files, and the lean body carries no personal values.
- Decided: `dist/personas/` is regenerated by an explicit script and guarded by the gate, not written as a side effect of every compose. Reason: a hidden write on unrelated targets breaks the per-target contract, and the gate catches staleness.
- Decided: Pi gets no emitter and no agents dir. Reason: Pi documents no sub-agents.
- Decided: OpenClaw reuses `openclaw-native` (already goldened by `workflow-upgrades#2`) and gets skills only. Reason: the renderer exists, and live deploy is governed by the throwaway-agent rule.
- Decided: Cursor is not a registry row. Reason: it is not in the remit list, and it already reads the shared dir.
- Decided: Gemini `tools` is written as a YAML block list. Reason: the docs say "tool names" without showing syntax. A list is the natural YAML form, and the smoke test confirms it.

## Issue dispositions (D11)

- #31, #32, #33: built by groups 4, 5 and 3. The orchestrator calls in #32 and #33 are resolved above.
- #36: group 8.
- #3 (OpenClaw emitter): superseded. The renderer exists and is goldened, and skills reach OpenClaw through the shared dir.
- #30 (Cursor reuse of `.claude/agents`): superseded. Cursor reads the shared skills dir with no work.
- #35 (Continue): closed as skipped.
- #34 (Amp): stays open and deferred.
- #23 is not handled here. It belongs to `workflow-upgrades`.

## Risks

- Codex or Gemini may reject extra Claude-only frontmatter (`triggers`, `preamble-tier`, `hooks`). gstack's Codex host allowlists only `name` and `description`, which hints at caution. Mitigation: the group 9 smoke test checks this. The fallback is stripped copies.
- Codex's 8,000-char skill listing cap drops descriptions when many skills are wired. Mitigation: the smoke test records how many skills Codex lists. Trimming is via `budget-and-usage` and the existing `-repo` overlay subtractions.
- OpenCode and Cursor may list duplicates. Mitigation: the documented OpenCode env switch, and the smoke test records what actually happens.
- Vendor drift. Mitigation: the dated facts table in `docs/harnesses.md`, encoded in the validators.
- The Antigravity global skills path is disputed between sources. Mitigation: smoke-test it before trusting the row.
