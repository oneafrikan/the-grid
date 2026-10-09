## Purpose

Generate native subagent files for the harnesses that have them, from the same role source as the Claude Code output, and deliver orchestrator roles to every harness as skills.

## ADDED Requirements

### Requirement: Generated specialist subagents for Codex, Gemini CLI and OpenCode

`compose.py` SHALL provide targets `codex`, `gemini-cli` and `opencode` that each write one subagent file per specialist role in the harness's native format, derived from the same body as the Claude Code subagent, with a role's tool allowlist mapped to the harness's own restriction mechanism and no model field.

#### Scenario: Codex file shape
- **WHEN** `compose.py <config> --target codex` runs for a role with `tools: [Read, Grep, Glob, Bash]`
- **THEN** it writes `<slug>-<role>.toml` with `name`, `description`, `sandbox_mode = "read-only"` and `developer_instructions`, and no `model`

#### Scenario: Gemini tool mapping
- **WHEN** `compose.py <config> --target gemini-cli` runs for a role with an allowlist
- **THEN** the frontmatter `tools` list holds the mapped Gemini tool names and no `model`

#### Scenario: Unmapped tool fails closed
- **WHEN** a role's allowlist names a tool with no Gemini mapping
- **THEN** compose exits non-zero with `E_TOOL_UNMAPPED` naming the role and tool, and writes no files

#### Scenario: OpenCode permissions
- **WHEN** `compose.py <config> --target opencode` runs for a role whose allowlist lacks Edit and Write
- **THEN** the file has `mode: subagent` and `permission.edit: deny`

#### Scenario: Role without an allowlist
- **WHEN** a specialist has no `tools:` in `role.yaml`
- **THEN** its generated file has no sandbox, tools or permission restriction

#### Scenario: Claude output is unchanged
- **WHEN** the shared body is extracted for the new targets
- **THEN** `compose.py <config> --target claude-code --check` still reports up to date

### Requirement: Orchestrators reach every harness as skills

The system SHALL deliver each orchestrator role to non-Claude harnesses as the same `SKILL.md` produced for Claude Code, and the new agent targets MUST NOT emit a file for an orchestrator role.

#### Scenario: Orchestrator is not an agent file
- **WHEN** any new agent target runs on a config containing an orchestrator
- **THEN** no agent file is written for it

#### Scenario: Orchestrator skill reaches the shared directory
- **WHEN** `harness:codex` is active and the project is composed
- **THEN** the orchestrator's skill folder is linked into `~/.agents/skills`
