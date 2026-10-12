# Harnesses

the-grid wires its curated skills into Claude Code by default. With a harness opted in, `scripts/wire.sh` also fans the same wired set out to the other agent harnesses (Codex CLI, OpenCode, Gemini CLI, Pi, OpenClaw, Antigravity CLI). Nothing is hand-copied: the registry drives it, and the links are generated on every run.

This page covers the skill wiring (spec `harness-wiring`) and rules delivery (spec `harness-rules-delivery`). Agent formats and the real-install smoke table are added as those parts land.

## Shared-dir finding

Codex, Gemini CLI, OpenCode, Pi and OpenClaw all read `~/.agents/skills` (Cursor does too). So the wired skill set is linked there **once**, and that one dir serves all of them.

- Activation is per directory, not per harness: activating any one of them puts the skills in front of every installed harness that reads `~/.agents/skills`.
- OpenCode (and Cursor) also read `~/.claude/skills`, so a skill present in both dirs may be listed twice there. Not verified. OpenCode has a switch for it: set `OPENCODE_DISABLE_CLAUDE_CODE_SKILLS=1` to stop it reading the Claude dir.
- Codex caps its skill listing at 2% of context or 8,000 chars; past that, descriptions are dropped. A large wired set will overflow on Codex. Trim with `-repo` / `-repo/skill` overlay subtractions.

## Verified vendor facts (fetched 2026-10-09)

| Harness | Skills (user scope) | Subagents | Global instructions | Sources |
|---|---|---|---|---|
| Codex CLI | `~/.agents/skills` (also repo `.agents/skills`, admin `/etc/codex/skills`). Symlinked skill folders are followed. `~/.codex/skills` is not documented. Skills list capped at 2% of context or 8,000 chars. | `~/.codex/agents/*.toml`; required `name`, `description`, `developer_instructions`; optional `model`, `model_reasoning_effort`, `sandbox_mode`, `mcp_servers`, `skills.config`. | `~/.codex/AGENTS.md` (or `AGENTS.override.md`); project docs capped by `project_doc_max_bytes` = 32 KiB | learn.chatgpt.com/docs/build-skills, /docs/agent-configuration/subagents, /docs/agent-configuration/agents-md |
| Gemini CLI | `~/.gemini/skills/` or alias `~/.agents/skills/`; `.agents` wins over `.gemini`. Symlinks not mentioned. | `~/.gemini/agents/*.md`; frontmatter `name`, `description`, optional `tools`, `model`, `temperature`, `max_turns`, `timeout_mins`, `kind`, `mcpServers`. | `~/.gemini/GEMINI.md`; `@file.md` imports | geminicli.com/docs/cli/skills/, /docs/core/subagents/, /docs/cli/gemini-md/ |
| Antigravity CLI (`agy`; Gemini CLI's successor for individual-tier users since 2026-06-18) | global `~/.gemini/antigravity-cli/skills/`; workspace `.agents/skills/` | location undocumented | workspace `GEMINI.md` / `AGENTS.md`; global `~/.gemini/GEMINI.md`; global AGENTS.md undocumented | developers.googleblog.com (Gemini CLI to Antigravity CLI transition post), antigravity.google/docs/cli/gcli-migration. Third-party sources disagree on `~/.antigravity` vs `~/.gemini`: **the path is unverified**. |
| OpenCode | `~/.config/opencode/skills/<n>/SKILL.md`; also reads `~/.agents/skills` and `~/.claude/skills`. `name` must match `^[a-z0-9]+(-[a-z0-9]+)*$` and equal the dir; `description` 1-1024; unknown fields ignored. | `~/.config/opencode/agents/<name>.md`; frontmatter `description` (required), `mode`, `model`, `temperature`, `permission`. | `~/.config/opencode/AGENTS.md`, falling back to `~/.claude/CLAUDE.md` | opencode.ai/docs/skills/, /docs/agents/, /docs/rules/ |
| Pi | `~/.agents/skills/` and `.agents/skills/`; first name wins, warning on collision. | none documented | `~/.pi/agent/AGENTS.md` (falls back to `CLAUDE.md`) | github.com/badlogic/pi-mono (packages/coding-agent docs) |
| OpenClaw | `~/.agents/skills` (personal), `<workspace>/skills`, `~/.openclaw/skills`. Symlinked folders allowed in personal and managed roots if every `SKILL.md` realpath stays inside its resolved skill dir. | agents are workspaces | workspace `AGENTS.md`, `SOUL.md`, `USER.md`, `IDENTITY.md`, `MEMORY.md` | docs.openclaw.ai/tools/skills, /concepts/agent-workspace |

Agent Skills spec (agentskills.io/specification): `name` at most 64 chars, lowercase/digits/hyphens, equal to the parent dir; `description` 1-1024. The spec does not say whether unknown frontmatter fields are ignored (OpenCode says it ignores them; the Codex and Gemini docs are silent). Whether Codex and Gemini accept Claude-only fields (`triggers`, `allowed-tools`, `hooks`) is for the real-install smoke test to confirm.

## The registry

`scripts/lib/harnesses.txt`, one row per harness, whitespace-separated, `#` comments, `-` = none:

| Column | Meaning |
|---|---|
| `harness` | name used in `harness:<name>` and `GRID_HARNESS` |
| `skills_dir` | where wired skills are linked |
| `agents_dir` | where composed specialist agents are linked |
| `compose_target` | `compose.py --target` whose `_<target>/agents/*` output is linked there |
| `rules_file` | the global instruction file (rules delivery) |
| `rules_harness` | value for `rules.py emit --harness` |

`wire.sh` checks every row before it writes anything (`harness_registry_check`): exactly six columns, and `skills_dir`, `agents_dir` and `rules_file` must each be `-`, an absolute path or `~/...` with no `..` component, else it exits 2 naming the row. `HARNESS_REGISTRY=<file>` points wire.sh at another registry file only together with `GRID_ALLOW_REGISTRY=1` (a test-only switch, like `GRID_ALLOW_FILE=1`); on its own the variable is ignored.

A leading `~/` expands to the harness base, `${GRID_DRY_HOME:-${GRID_HARNESS_HOME:-$HOME}}`. `claude` is listed for reference only: wire.sh keeps using `SKILLS_DIR` / `AGENTS_DIR` for Claude exactly as before. Antigravity is skills-only; Pi and OpenClaw are skills-only too (Pi documents no sub-agents; OpenClaw agents come from `compose.py --target openclaw-native`).

`compose_target` is filled in from the start. wire.sh links `agent-factory/projects/<p>/_<compose_target>/agents/*` only when that dir exists and the project is wired, so a target that has not been composed simply links nothing.

## Activating a harness

- Per machine, in `machines/<host>.txt` (or the baseline, or `machines/<host>.local.txt`):

  ```
  harness:codex
  harness:opencode
  -harness:codex      # removes it again (a later file wins)
  ```

- One-off, for a single run: `GRID_HARNESS=codex,pi bash scripts/wire.sh`.
- `claude` is always active. `harness:claude` is accepted and does nothing.
- Default (no entry anywhere): Claude only, and no other harness dir is created.
- An unknown name exits 2 before anything is touched and lists the valid names. Names in the manifest are checked even while `GRID_HARNESS` overrides them, and a `GRID_HARNESS` that names no harness at all (`GRID_HARNESS=,`) exits 2 too.
- An active harness needs `python3` (the portability filter reads frontmatter with it). Without it wire.sh exits 2 before any write.

**`GRID_HARNESS` replaces the manifest set.** A one-off `GRID_HARNESS=pi` run deactivates every other harness. Teardown removes the grid links in every harness dir, then the active harnesses are linked again: a link in a dir shared with a harness that stays active (the `~/.agents/skills` group) is rebuilt in the same run, so only the per-harness dirs (`~/.codex/agents`, `~/.gemini/agents`, ...) of the deactivated harnesses lose their links. Use the overlay for anything lasting.

## What gets linked

Skills: the set is whatever grid-owned links `SKILLS_DIR` holds after the Claude wiring, so Claude's precedence (a root skill beats a same-named repo skill) and dedupe apply unchanged, and each name is linked once per distinct dir. Each skill must pass the portability filter first.

Agents: the files in `agent-factory/projects/<p>/_<compose_target>/agents/`, for wired projects.

### Skip reasons

A skill that fails a check is not linked into a non-Claude dir. It is still linked for Claude. The reason is the last column of its `.wired.manifest` row:

```
skill@~/.agents/skills<TAB>claude-skill<TAB><target><TAB>skipped<TAB>claude-specific
```

| Reason | Meaning |
|---|---|
| `no-frontmatter` | `SKILL.md` has no leading `---` block |
| `name-mismatch` | frontmatter `name` differs from the dir name |
| `name-invalid` | dir name fails `^[a-z0-9]+(-[a-z0-9]+)*$` or is over 64 chars |
| `description-long` | description over 1024 chars after YAML folding |
| `claude-specific` | a file in the skill mentions `~/.claude`, `$HOME/.claude`, `.claude/` or `CLAUDE_` |
| `runtime-root` | the link targets a submodule root (the `gstack` runtime-root link), which is not a skill |
| `exists, not managed` | something is already at the destination (see below) |
| `name clash with <project>` | two composed projects ship an agent of the same name; the first project (alphabetical) is linked, the second is skipped |

Rows are `skill@<~dir>` / `agent@<~dir>` (the dir in `~/` form, so the file is home-independent). Portability skips print no stdout line; the manifest is where to read them: `grep skipped .wired.manifest`.

## Pi and OpenClaw (skills-only rows)

Both rows have `-` for `agents_dir`, `compose_target` and (OpenClaw) `rules_file`, so `wire.sh` links skills into the shared dir and nothing else. Neither harness gets a dir of its own: no `~/.pi/agent/agents`, nothing under `~/.openclaw/`.

| Harness | Agents | Notes |
|---|---|---|
| Pi | No subagent emitter: Pi documents no sub-agents. | Pi keeps the first skill it discovers on a name clash, so a duplicate name must never be linked. `wire.sh` already guarantees it: one link per name, and a root skill beats a same-named repo skill. |
| OpenClaw | Agents are workspaces. Compose them with `compose.py --target openclaw-native` and deploy with `agent-factory/scripts/deploy_openclaw.sh` (both unchanged by this change). `wire.sh` never touches them. | See the symlink rule below. |

**OpenClaw symlink rule** (docs.openclaw.ai/tools/skills, fetched 2026-10-11). `~/.agents/skills` is a personal root. A personal root may hold symlinked skill folders, as the grid links are, provided every `SKILL.md` realpath stays inside its resolved skill directory. A grid skill dir whose `SKILL.md` is itself a symlink out of that dir would be skipped with a once-per-process warning.

`skills.load.allowSymlinkTargets` is an array of trusted target roots in `openclaw.json`, e.g. `allowSymlinkTargets: ["~/path/to/skills"]`. Per the vendor page it applies to workspace, project-agent and extra-dir discovery (a skill root symlinked to somewhere outside the configured root), not to the personal roots. Set it only if you point an OpenClaw workspace `skills/` dir at the grid; the shared-dir wiring does not need it. Not exercised on a real OpenClaw install yet (that is the real-install smoke test).

## Ownership rules

- Only symlinks whose target is inside the grid dir (`$GRID_DIR/...`) are ever removed. Real files and dirs, foreign symlinks, and links into a sibling such as `<grid>-private` are left alone.
- Teardown covers every non-Claude registry dir, active or not, so deactivating a harness removes its links.
- **Existing entries in a non-Claude dir are never replaced.** `~/.agents/skills` is also written by other tools, so a real dir, a foreign symlink or a dangling symlink at the destination wins and the grid skips it (`exists, not managed`; stdout `  skip (~/.agents/skills: exists, not managed): <name>`). The Claude dirs follow the same rule for a foreign or dangling symlink and for a real file (`skip (not managed)`); only a link into the grid is replaced there. The line deliberately does not start `skip (real dir, not managed)`: `scripts/reconcile.sh` parses that prefix and would delete the same-named dir in the Claude skills dir.
- A skills dir that is itself a symlink is fine: it is followed, both when tearing down and when listing for `--check`.
- Dirs are created only when a link is about to be made.

## Limits

Layouts the fan-out does not handle. Each is documented rather than implemented (a deliberate choice, not an oversight):

- **Aliased agents dirs.** Two harnesses whose agents dirs are aliased to one directory (a symlink, or two registry rows pointing at the same place) are unsupported: the grid sees two dirs, links into both, and `--check` reports false drift for the second. Give each harness its own dir.
- **Removed registry rows leave stale links.** Teardown walks the dirs of the rows that exist now. Remove or rename a row only after `-harness:<name>` has been wired once; otherwise the links in that harness's dirs stay behind, and `--check` cannot see them because it no longer knows the dir.
- **The shared dir follows the Claude dir.** The skills fanned out to `~/.agents/skills` are whatever grid links the Claude skills dir holds after wiring, so when a Claude slot is held by something that is not a grid link (a real dir or a foreign link, `skip (not managed)`), the shared dir lags the Claude dir for that name: it is not linked there either.

## Drift check

`wire.sh --check` stays read-only. It wires into a throwaway dry home (`GRID_DRY_HOME`) and diffs every distinct non-Claude registry dir against the live one, active or not: a stale grid link in a deactivated harness is drift. A destination occupied by a real entry or foreign symlink is never drift, because a real wire would skip it too.

## Rules delivery

`rules:<pack>` entries (see `docs/rules.md`) are also delivered to the global instruction file of each active harness, by calling `scripts/rules.py emit` on it. Nothing is injected by default: **you opt in per harness by creating the file yourself** (a regular file, not a symlink; an empty one is enough), and `wire.sh` never creates it.

| Harness | Instruction file (`rules_file`) | `rules.py emit --harness` |
|---|---|---|
| Codex | `~/.codex/AGENTS.md` | `agents-md` |
| OpenCode | `~/.config/opencode/AGENTS.md` | `agents-md` |
| Gemini CLI | `~/.gemini/GEMINI.md` | `gemini` |
| Pi | `~/.pi/agent/AGENTS.md` | `agents-md` |
| Antigravity, OpenClaw | none (`-`): never touched | none |

What `wire.sh` does for each file in that column:

| Situation | Result |
|---|---|
| Harness active, a pack wired, regular file | the managed block is written (or refreshed); text outside it is left as it was |
| Same, file absent | no file is created; `.wired.manifest` row `rules@<~file>`, status `skipped`, reason `rules-file-absent` |
| Same, file is a symlink | the target is not written through; same row with reason `rules-file-symlink` |
| Same, path is a directory or other non-regular file | not written; same row with reason `rules-file-not-regular` |
| Same, registry row is not a `~/`-relative `AGENTS.md`, `GEMINI.md` or `CLAUDE.md` | not written; same row with reason `rules-file-not-allowed` |
| Same, but the block would be over the 12288-byte cap | nothing is written and an existing block is left as it was; row reason `over-cap`; wire stays green |
| Harness inactive, file holds a damaged block (unbalanced markers) | not touched; warning plus row reason `markers-unbalanced`; wire stays green |
| Harness inactive, or no pack wired, file holds a block | the block is removed |
| Harness inactive, or no pack wired, file has no block | no call at all, so an empty opt-in file stays |

- **Token cost:** the block is loaded on every session (these harnesses have no path scoping). `rules.py` caps it at 12288 bytes and, for an over-cap selection, writes nothing (exit 3) rather than truncating; `wire.sh` prints `skipped, block is N bytes, over the 12288-byte cap` and keeps going, so Codex/Gemini rules go stale until you select fewer packs. Wire only the packs you want always loaded.
- **Removal keeps the file:** if removing the block leaves the file empty, `rules.py` truncates it to 0 bytes and keeps it, so the opt-in survives and re-enabling delivers the block again. Removal also takes back the one blank separator line the append added, so a newline-terminated file is restored byte for byte (a file with no final newline gains one). A CRLF file (every newline CRLF) gets a CRLF block.
- **Codex prefers `AGENTS.override.md`** over `AGENTS.md` when it exists. The grid only manages `AGENTS.md`, so the block is not read while an override file is present; `wire.sh` prints a warning on every run when it finds one beside the file.
- Every skip is printed on stderr (`rules (~/.codex/AGENTS.md): skipped, file is a symlink`) as well as recorded in `.wired.manifest`. `wire.sh --check` stays silent about skips, which are not drift.
- A symlinked instruction file is never edited, not even to remove an old block, because the target may belong to another tool or be regenerated elsewhere.
- A `rules.py` failure is reported on stderr, the rest of the wire still runs, and `wire.sh` then exits 1.
- `wire.sh --check` runs the same decisions with `rules.py emit --check` against the live files (read-only; its output says `would write` / `would remove`): a hand-edited block, a missing block, or a block that should be gone is drift. An absent or symlinked file, an over-cap selection and a damaged block in an inactive harness's file are not.

## Agent targets

Specialist roles become native subagents on harnesses that have them. Orchestrators are never emitted as agent files: they ship as skills (the `claude-code` skill folders) and reach the shared skills dir through the normal wiring. Every agent target shares one prompt body (`render_subagent_body` in `compose.py`, the same text as the Claude subagent), the same name and description as the Claude subagent, and never writes a `model`. Each target writes only its own `_<target>/` dir under the project, so recomposing one never disturbs another.

### Codex CLI

Compose, then wire (Codex only reads the files once wire.sh has linked them into `~/.codex/agents/`):

```
agent-factory/.venv/bin/python agent-factory/compose.py agent-factory/examples/grid.yaml --target codex
GRID_HARNESS=codex bash scripts/wire.sh        # or put harness:codex in machines/<host>.txt
```

Output: `agent-factory/projects/<project>/_codex/agents/<name>.toml`, one per specialist, where `<name>` is `<slug>-<role>` (`grid-qa-engineer`).

```toml
name = "grid-qa-engineer"
description = "QA Engineer. The release gate. ... Use this subagent for qa-engineer work."
sandbox_mode = "read-only"
developer_instructions = """
You are the **QA Engineer**, a specialist agent on a composed dev team. ...
"""
```

- Required keys are `name`, `description` and `developer_instructions`. `name` is the agent's identity, not the filename.
- Key order is fixed: `name`, `description`, `sandbox_mode`, `developer_instructions`.
- Sandbox mapping: `sandbox_mode = "read-only"` is written only when the role's `role.yaml` has a `tools:` allowlist containing neither `Edit` nor `Write` (today `qa-engineer` and `security-reviewer`). A role with no allowlist, or one that can edit, gets no `sandbox_mode` and inherits Codex's default.
- A read-only sandbox also blocks writes through Bash. That is stricter than Claude, where an allowlisted Bash can still write, and it errs safe for read-only roles.
- `model` and the other optional keys (`model_reasoning_effort`, `mcp_servers`, `skills.config`) are never written.
- Strings are escaped by hand (the stdlib has no TOML writer) and verified by round-tripping through `tomllib`; `tests/lib/validate_harness.py codex-agent FILE...` checks any generated file against the format above.
- Not verified on a real Codex yet (the real-install smoke test is a later, human step).

### OpenCode

| | |
|---|---|
| Skills dir | `~/.agents/skills` (shared; OpenCode also reads `~/.config/opencode/skills` and `~/.claude/skills`) |
| Agents dir | `~/.config/opencode/agents/` (honours `XDG_CONFIG_HOME`, see "Paths and environment") |
| Compose target | `opencode` |
| Agent file | `<name>.md`, the filename is the agent id |

Compose, then wire (OpenCode only sees the files once wire.sh has linked them into its agents dir):

```
agent-factory/.venv/bin/python agent-factory/compose.py agent-factory/examples/grid.yaml --target opencode
GRID_HARNESS=opencode bash scripts/wire.sh     # or put harness:opencode in machines/<host>.txt
```

Output: `agent-factory/projects/<project>/_opencode/agents/<name>.md`, one per specialist, where `<name>` is `<slug>-<role>` (`grid-qa-engineer`).

```markdown
---
description: QA Engineer. The release gate ... Use to verify work before release.
mode: subagent
permission:
  edit: deny
  webfetch: deny
---

You are the **QA Engineer**, a specialist agent on a composed dev team. ...
```

- Required frontmatter is `description`; `mode` is always `subagent`. The body is the system prompt, identical to the Claude and Codex agents.
- Key order is fixed: `description`, `mode`, `permission`. Long descriptions are folded over several lines by the YAML writer, which is valid YAML.
- Permission mapping: `permission` is written only when the role's `role.yaml` has a `tools:` allowlist that denies something. Keys, in this order: `edit: deny` when neither `Edit` nor `Write` is listed, `bash: deny` when `Bash` is absent, `webfetch: deny` when neither `WebFetch` nor `WebSearch` is listed. A key that is not written inherits OpenCode's default. A role with no allowlist gets no `permission` block.
- Today that gives `qa-engineer` and `security-reviewer` `edit: deny` and `webfetch: deny` (they keep `Bash`, so no `bash` key).
- `model` is never written (model ids are provider-specific and rot), and neither is the deprecated `tools` key.
- Skills reach OpenCode through the shared skills dir, not through this target. OpenCode also reads `~/.claude/skills`, so a skill present in both dirs may be listed twice (not verified); set `OPENCODE_DISABLE_CLAUDE_CODE_SKILLS=1` to stop it reading the Claude dir.
- Checkers: `tests/lib/validate_harness.py opencode-agent FILE...` validates an agent file (`description` present, `mode: subagent`, permission values `ask`/`allow`/`deny`), and `validate_harness.py skill DIR...` validates a skill dir against the OpenCode skill rules (dir name `^[a-z0-9]+(-[a-z0-9]+)*$` and at most 64 chars, frontmatter `name` equal to the dir, description 1 to 1024 chars). The tests run the second over every link `wire.sh` puts in the shared dir.
- Not verified on a real OpenCode yet (the real-install smoke test is a later, human step): that the `permission` mapping loads, that a symlinked agent file is found, and whether a skill is listed twice.

## Paths and environment

- `GRID_HARNESS_HOME` sets the base for every non-Claude dir (default `$HOME`); tests point it at a temp dir.
- `GRID_DRY_HOME` wins over it and redirects every harness path, so a dry run can never write under the real home.
- `XDG_CONFIG_HOME` is honoured for OpenCode's `~/.config/...` paths **only** when both `GRID_DRY_HOME` and `GRID_HARNESS_HOME` are unset, and only when it is an absolute path (a relative one is ignored, as the XDG spec says).
- `CODEX_HOME` and `PI_CODING_AGENT_DIR` are **not** honoured. If you relocate those, edit the row in `scripts/lib/harnesses.txt`.

## Single-file personas

Single-file personas for chat-UI Projects: `dist/personas/<role>.md`

## Gemini CLI and Antigravity

### Gemini CLI (agent target `gemini-cli`)

Compose, then wire (Gemini only reads the files once wire.sh has linked them into `~/.gemini/agents/`; skills come from the shared `~/.agents/skills`):

```
agent-factory/.venv/bin/python agent-factory/compose.py agent-factory/examples/grid.yaml --target gemini-cli
GRID_HARNESS=gemini bash scripts/wire.sh        # or put harness:gemini in machines/<host>.txt
```

Output: `agent-factory/projects/<project>/_gemini-cli/agents/<name>.md`, one per specialist, `<name>` = `<slug>-<role>` (`grid-qa-engineer`).

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

You are the **QA Engineer**, a specialist agent on a composed dev team. ...
```

- Key order is fixed: `name`, `description`, `tools`. `model` is never written (Gemini's default is `inherit`).
- `tools` is written only when the role's `role.yaml` has a `tools:` allowlist. A role with none gets no `tools` key and inherits every tool, as on Claude.
- The allowlist is mapped in the role's listed order, first occurrence wins (`GEMINI_TOOLS` in `compose.py`):

  | Claude tool | Gemini tools |
  |---|---|
  | `Read` | `read_file`, `read_many_files` |
  | `Grep` | `grep_search` |
  | `Glob` | `glob`, `list_directory` |
  | `Bash` | `run_shell_command` |
  | `Edit` | `replace` |
  | `Write` | `write_file` |
  | `WebFetch` | `web_fetch` |
  | `WebSearch` | `google_web_search` |

- A tool with no mapping is a hard error: `E_TOOL_UNMAPPED: <role>: tool '<tool>' has no Gemini CLI mapping`, exit 1. The check runs before the `_gemini-cli` dir is wiped, so a failed compose leaves the previous output (and any other target) untouched. Dropping the tool silently would change what a read-only role can do.
- The docs say only "tool names" for `tools`, with no syntax shown, so the list is a YAML block list (the natural form). Not verified on a real Gemini CLI yet (the real-install smoke test is a later, optional, human step).
- `tests/lib/validate_harness.py gemini-agent FILE...` checks a generated file: `name` matches `^[a-z0-9_-]+$`, `description` is non-empty, `tools` (if present) is a block list, and there is no `model`.
- Subagents cannot call subagents on Gemini CLI, so a role that delegates (an orchestrator) is never emitted as an agent file; it reaches Gemini as a skill.

### Antigravity CLI (skills-only)

- Gemini CLI's successor for individual-tier users since **2026-06-18** (Google's transition post). `agy` is the binary.
- The registry row `antigravity` has `-` for `agents_dir`, `compose_target` and `rules_file`: `GRID_HARNESS=antigravity` links the wired skills into `~/.gemini/antigravity-cli/skills/` and creates no agents dir and no `~/.agents/skills`. Its subagent location and a global `AGENTS.md` are undocumented, so no emitter and no rules delivery.
- **The skills path is unverified.** Google's migration docs give `~/.gemini/antigravity-cli/skills/`; third-party sources disagree (`~/.antigravity` vs `~/.gemini`). Confirm on a real `agy` install before relying on the row (optional human smoke test, tasks 9.4). If the path is wrong, edit the one row in `scripts/lib/harnesses.txt`.
