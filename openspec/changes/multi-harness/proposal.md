## Why

the-grid wires skills, rules and composed agents only into Claude Code. Its stated remit is every harness: Codex, Gemini CLI, OpenCode, Pi and OpenClaw. Vendor docs checked on 2026-10-09 show all five read the same `SKILL.md` format from one shared directory, `~/.agents/skills`, so getting skills to them is cheap. Agents need a small generated emitter per harness. ECC's hand-ported harness mirrors drifted to 11-50% coverage, so here every copy is generated from one source and pinned by goldens.

## What Changes

- Add a harness registry (`scripts/lib/harnesses.txt`) and a `harness:<name>` manifest entry (plus `GRID_HARNESS` env). `wire.sh` links the wired skill set into `~/.agents/skills`, one directory that Codex, Gemini CLI, OpenCode, Pi and OpenClaw (and Cursor) all read.
- Filter what reaches non-Claude harnesses: skills that reference Claude-only paths or break Agent Skills name/description limits are skipped, and the reason is recorded.
- Add `compose.py` targets `codex` (TOML subagents), `opencode` and `gemini-cli` (Markdown subagents). Orchestrator roles reach every harness as skills, which resolves the open design calls in #32 and #33.
- Pi, OpenClaw and Antigravity get skills only. Pi has no subagents. OpenClaw keeps its existing `openclaw-native` target.
- Deliver `rule-packs` rules into each harness's global instruction file by calling `scripts/rules.py emit --harness agents-md|gemini`. This happens only when that file already exists.
- Extend the `workflow-upgrades` golden-output tests to the new targets, and add per-harness format validators.
- Add a committed `dist/personas/<role>.md` export (#36).
- Issue dispositions: #31, #32, #33, #36 are built here. #3 and #30 are superseded. #35 is closed as skipped. #34 stays deferred.

## Capabilities

### New

- `harness-wiring`: the harness registry, the active-harness set, shared-directory skill wiring, the portability filter, ownership and drift checks.
- `harness-agent-targets`: generated subagent files for Codex, OpenCode and Gemini CLI, plus orchestrators delivered as skills.
- `harness-rules-delivery`: placing compiled rule packs into each harness's existing global instruction file.
- `harness-conformance`: goldens and format validators for every generated harness artefact.
- `portable-personas`: committed single-file personas for chat-UI Projects.

### Modified

- None. `openspec/specs/` is empty today.

## Impact

- Code: `scripts/wire.sh`, new `scripts/lib/{harness.sh,harnesses.txt,skill-portable.sh,skill_frontmatter.py}`, `scripts/build-personas.sh`, `scripts/gate.sh`, `agent-factory/compose.py`, `scripts/compose-goldens.sh` (target list only), `tests/`, `docs/harnesses.md`, `CLAUDE.md`.
- Depends on `workflow-upgrades#2` for the golden harness, `GRID_USER_CONFIG` and `agent-factory/user.public.yaml`. This change does not re-introduce them.
- Depends on `rule-packs#2` (the `rules:<pack>` manifest tier) and `rule-packs#4` (the `rules.py emit` block emitter) for rules delivery.
- New committed output: `dist/personas/`.

## Non-goals

- No path-rewriting of Claude-specific skills (gstack's approach). Skills that reference `~/.claude` stay Claude-only. Most of these are the 45 gstack skills.
- No per-harness skill subsets. The shared directory is one set for every harness that reads it.
- No hooks translation, no MCP server wiring, no per-harness model pinning. Generated non-Claude agents inherit the session model.
- No Cursor, Amp, Continue or Antigravity subagent emitters. #34 stays deferred and #35 is closed as skipped. Cursor still gets skills from the shared directory.
- No OpenCode `mode: primary` orchestrators. Orchestrators are skills everywhere.
- No `wire.sh --harness` flag. The `GRID_HARNESS` env var covers one-off runs.
- No helper script that composes every target. Compose commands are documented in `docs/harnesses.md`.
- No new live OpenClaw deploy tooling. `deploy_openclaw.sh` and the throwaway-agent rule stand.
- No change to Claude Code output. Existing targets stay byte-identical, and the `workflow-upgrades` goldens prove it.
- No installer or `grid` CLI work. That is `manifest-lock-install`.
