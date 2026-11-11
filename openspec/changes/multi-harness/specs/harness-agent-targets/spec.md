## Purpose

Generate native subagent files for the harnesses that support them, from the same role source as the Claude Code output, and deliver orchestrator roles to every harness as skills.

## ADDED Requirements

### Requirement: Generated specialist subagents for Codex, OpenCode and Gemini CLI

`compose.py` SHALL provide targets `codex`, `opencode` and `gemini-cli` that each write one subagent file per specialist role, in the harness's native format. Each file SHALL carry the same name, description and body as the Claude Code subagent, map the role's tool allowlist to the harness's own restriction mechanism, and have no model field.

#### Scenario: Codex file shape
- **WHEN** `compose.py <config> --target codex` runs for a role with `tools: [Read, Grep, Glob, Bash]`
- **THEN** it writes `<name>.toml` with `name`, `description`, `sandbox_mode = "read-only"` and `developer_instructions`, and no `model`

#### Scenario: OpenCode permissions
- **WHEN** `compose.py <config> --target opencode` runs for a role whose allowlist lacks Edit, Write, WebFetch and WebSearch
- **THEN** the file has `mode: subagent`, `permission.edit: deny` and `permission.webfetch: deny`

#### Scenario: Gemini tool mapping
- **WHEN** `compose.py <config> --target gemini-cli` runs for a role with an allowlist
- **THEN** the frontmatter `tools` list holds the mapped Gemini tool names, and there is no `model`

#### Scenario: Role without an allowlist
- **WHEN** a specialist has no `tools:` in `role.yaml`
- **THEN** its generated file has no sandbox, tools or permission restriction

#### Scenario: Claude output is unchanged
- **WHEN** the shared body is extracted for the new targets
- **THEN** the committed `claude-code` golden still passes with no update

### Requirement: Generated specialist subagents for Antigravity CLI

`compose.py` SHALL provide a target `antigravity` that writes one `<name>.md` per specialist role for `~/.gemini/config/agents/`. Each file SHALL carry the same name, description and body as the Claude Code subagent, with frontmatter `subagent: true`, `mainAgent: false` and a `tools` list that is always written, and no `model` or `color`.

#### Scenario: Role without an allowlist
- **WHEN** `compose.py <config> --target antigravity` runs for a role with no `tools:` in `role.yaml`
- **THEN** the frontmatter has `tools: [read_file, edit_file, write_file, run_command, manage_task, search_web]`

#### Scenario: Allowlist mapping
- **WHEN** it runs for a role with `tools: [Read, Grep, Glob, Bash]`
- **THEN** `tools` is `[read_file, run_command, manage_task]` (mapped in order, de-duplicated; `Skill` is dropped)

#### Scenario: Built-in name clash
- **WHEN** a composed agent name is `self`, `browser`, `research`, `deepagent` or `review-agent`
- **THEN** compose exits `E_NAME_RESERVED` and writes nothing

#### Scenario: Hand-written file in the agents dir
- **WHEN** `GRID_HARNESS=antigravity` wires and `~/.gemini/config/agents/` already holds a real file
- **THEN** it is left untouched and reported `skip (... exists, not managed)`

### Requirement: Orchestrators reach every harness as skills

The system SHALL deliver each orchestrator role to non-Claude harnesses as the same `SKILL.md` folder produced for Claude Code. The new agent targets MUST NOT emit a file for an orchestrator role.

#### Scenario: Orchestrator is not an agent file
- **WHEN** any new agent target runs on a config containing an orchestrator
- **THEN** no agent file is written for it

#### Scenario: Orchestrator skill reaches the shared directory
- **WHEN** `harness:codex` is active and a wired project's `claude-code` output contains an orchestrator skill
- **THEN** that skill folder is linked into `~/.agents/skills`
