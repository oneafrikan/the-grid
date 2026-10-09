## Why

Agents repeat the same corrections every session because nothing carries habits from one session to the next. ECC's continuous-learning v2 shows the shape (capture, distil, inject) but also its failure modes: a user logged 10,557 observations and got 0 instincts, v1 and v2 both run, and the background observer costs tokens all day. the-grid needs the loop with the cost made explicit: opt-in per project, capture that costs zero tokens, one cheap batched analysis per project per week, and a hard cap on what is injected.

## What Changes

- Per-project opt-in flag `learning: on` in `.grid/project.yaml`. It is independent of the hook profile and off by default.
- A zero-token capture hook (PostToolUse, PostToolUseFailure, UserPromptSubmit) appends scrubbed, truncated observations to a machine-local file. Raw observations never leave the machine.
- A weekly batched analyser (`scripts/instincts.sh analyse`): a local digest step, then one `haiku` call per project per week with no tools, a dollar cap and an input cap. It writes confidence-scored instincts to the private repo.
- Instincts are scoped by a hash of the git remote, stored one file per host so seven machines never conflict in git, and promoted to global when the same id is active in 2+ projects.
- A SessionStart injector adds at most 6 instincts and 1500 characters, framed as untrusted context and never as instructions.
- `tank` is extended (no new subsystem): instincts become a named source, and a new `evolve` mode drafts candidate skills into the private store (never wired). `oracle` may offer preference-type instincts for per-entry approval.
- Each analysis run writes a `run-record.sh` line, and `instincts.sh status` shows the funnel (observations, candidates, instincts) so a silent 0-instinct failure is visible.

## Capabilities

### New
- `instinct-capture`: opt-in, zero-token, scrubbed, local-only observation capture.
- `instinct-store`: private-repo layout, remote-hash scoping, per-host files, promotion, sync, lifecycle.
- `instinct-analysis`: weekly batched, budget-capped distillation with deterministic confidence.
- `instinct-injection`: capped, ranked, untrusted-framed session-start injection.
- `learning-desk-instincts`: how tank and oracle consume instincts (evolve mode, propose-only).

### Modified
- None. No `openspec/specs/` baseline exists yet; edits to tank, oracle and the project.yaml template are covered by the new capabilities.

## Impact

- New: `scripts/instincts.sh`, `scripts/instincts/{lib,capture,analyse,inject}.py`, `tests/test_instincts_*.bats`, `docs/instincts.md`.
- Edited: `agent-factory/roles/tank/{AGENTS,SKILL}.md`, `agent-factory/roles/oracle/SKILL.md`, `skills/mine-learnings/SKILL.md` (one pointer), `docs/agent-retro.md`, `project-factory/templates/_common/.grid/project.yaml`, `CLAUDE.md` (key-files entry), and the hook-profiles settings emitter (one added block, depends on workstream 6).
- Private repo gains `learning/instincts/`. Machines gain one weekly schedule entry, installed by the operator.
- Cost: capture 0 tokens; analysis at most one haiku call per opted-in project per week (about $0.05 cap each); injection at most 1500 characters per session in opted-in projects only.
- Issues: closes #16 and #19; #20 closed as superseded only if Gareth agrees (see design Open questions).

## Non-goals

- No background observer, daemon or per-tool-call model call.
- No capture of tool outputs or file contents (only commands, paths and user prompts), and no capture without `learning: on`.
- No compile-time injection of LEARNINGS.md into composed agents (#20's literal ask).
- No cross-harness emitters; Claude Code hooks only. Other harnesses are workstream 11.
- No import/export of instincts between people, no sharing outside the private repo.
- No automatic editing of roles, skills or CLAUDE.md; tank proposes, the operator commits.
- No MCP server, vector search or dashboard.
- No capture for repos without a git remote (no stable project id).
