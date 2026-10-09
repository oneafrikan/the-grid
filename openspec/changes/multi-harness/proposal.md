## Why

the-grid wires skills, rules and composed agents only into Claude Code. Its stated remit is every harness: Codex, Gemini CLI, OpenCode, Pi and OpenClaw. Vendor docs verified on 2026-10-09 show five of these read the same `SKILL.md` format from one shared directory (`~/.agents/skills`), so skill reach is cheap. Agents need a small generated emitter per harness. ECC's hand-ported harness mirrors drifted to 11-50% coverage, so every copy here is generated from one source and checked against goldens.

## What Changes

- Add a harness registry (`scripts/lib/harnesses.tsv`) and a `harness:<name>` manifest entry. `wire.sh` gains `--harness` and links wired skills into each active harness's skills directory.
- Filter what reaches non-Claude harnesses: skills that reference Claude-only paths or break Agent Skills limits are skipped with a recorded reason.
- Add `compose.py` targets `codex` (TOML subagents), `gemini-cli` (Markdown subagents) and `opencode` (Markdown subagents). Orchestrator roles reach every harness as skills, which resolves the open design calls in #32 and #33.
- Pi and OpenClaw get skills and instruction files only. Pi has no subagents; OpenClaw keeps its existing `openclaw-native` target.
- Deliver the workstream-8 compiled rules into each harness's global instruction file inside a size-capped managed block.
- Add golden-output conformance tests for the new targets plus `claude-code` and `openclaw-native` (#23) and format validators per harness. Tests never touch a real home directory.
- Add a committed `dist/personas/<role>.md` export (#36).
- Supersedes or folds issues #3, #23, #30, #31, #32, #33, #34, #35, #36.

## Capabilities

### New

- `harness-wiring`: the harness registry, the active-harness set, shared-directory skill wiring, the portability filter, ownership and drift checks.
- `harness-agent-targets`: generated subagent files for Codex, Gemini CLI and OpenCode; orchestrators as skills.
- `harness-rules-delivery`: placing workstream-8 compiled rules into each harness's global instruction file.
- `harness-conformance`: golden outputs and format validators for every generated harness artefact.
- `portable-personas`: committed single-file personas for chat-UI Projects.

### Modified

- None. `openspec/specs/` is empty today.

## Impact

- Code: `scripts/wire.sh`, new `scripts/lib/harness.sh`, `scripts/lib/harnesses.tsv`, `scripts/lib/skill-portable.sh`, `scripts/compose-harnesses.sh`, `scripts/build-personas.sh`, `agent-factory/compose.py`, `tests/`, `docs/harnesses.md`.
- Depends on workstream 8 (`rule-packs`) for rule content; the rules group is the only part that waits for it.
- Touches `machines/example.txt` and `baseline-submodules.example.txt` (comment grammar only).
- New committed output: `dist/personas/`.

## Non-goals

- No path-rewriting of Claude-specific skills (gstack's approach). Skills that reference `~/.claude` stay Claude-only. The 45 gstack skills are the bulk of this.
- No hooks translation to any harness.
- No MCP server wiring.
- No per-harness model pinning. Generated non-Claude agents inherit the session model.
- No Cursor, Amp, Continue or Antigravity subagent emitters. #34 and #35 stay deferred. Cursor still receives skills from the shared directory; its agent reuse (#30) is checked only by the optional smoke test.
- No new live OpenClaw deploy tooling. `deploy_openclaw.sh` and the throwaway-agent rule stand.
- No change to the Claude Code output. Existing targets must stay byte-identical.
- No installer or `grid` CLI work. That is workstream 3; this change adds one function the CLI can call later.
