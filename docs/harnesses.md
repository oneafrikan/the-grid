# Harnesses

the-grid wires its curated skills into Claude Code by default. With a harness opted in, `scripts/wire.sh` also fans the same wired set out to the other agent harnesses (Codex CLI, OpenCode, Gemini CLI, Pi, OpenClaw, Antigravity CLI). Nothing is hand-copied: the registry drives it, and the links are generated on every run.

This page covers the skill wiring (spec `harness-wiring`). Agent formats, rules delivery and the real-install smoke table are added as those parts land.

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
- An unknown name exits 2 before anything is touched and lists the valid names.
- An active harness needs `python3` (the portability filter reads frontmatter with it). Without it wire.sh exits 2 before any write.

**`GRID_HARNESS` replaces the manifest set.** A one-off `GRID_HARNESS=pi` run deactivates every other harness, and the teardown below then removes their grid links. Use the overlay for anything lasting.

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
- **Existing entries in a non-Claude dir are never replaced.** `~/.agents/skills` is also written by other tools, so a real dir, a foreign symlink or a dangling symlink at the destination wins and the grid skips it (`exists, not managed`; stdout `  skip (~/.agents/skills: exists, not managed): <name>`). This differs from the Claude dirs, where a grid link replaces a foreign symlink. The line deliberately does not start `skip (real dir, not managed)`: `scripts/reconcile.sh` parses that prefix and would delete the same-named dir in the Claude skills dir.
- A skills dir that is itself a symlink is fine: it is followed, both when tearing down and when listing for `--check`.
- Dirs are created only when a link is about to be made.

## Drift check

`wire.sh --check` stays read-only. It wires into a throwaway dry home (`GRID_DRY_HOME`) and diffs every distinct non-Claude registry dir against the live one, active or not: a stale grid link in a deactivated harness is drift. A destination occupied by a real entry or foreign symlink is never drift, because a real wire would skip it too.

## Paths and environment

- `GRID_HARNESS_HOME` sets the base for every non-Claude dir (default `$HOME`); tests point it at a temp dir.
- `GRID_DRY_HOME` wins over it and redirects every harness path, so a dry run can never write under the real home.
- `XDG_CONFIG_HOME` is honoured for OpenCode's `~/.config/...` paths **only** when both `GRID_DRY_HOME` and `GRID_HARNESS_HOME` are unset.
- `CODEX_HOME` and `PI_CODING_AGENT_DIR` are **not** honoured. If you relocate those, edit the row in `scripts/lib/harnesses.txt`.

## Single-file personas

Single-file personas for chat-UI Projects: `dist/personas/<role>.md`
