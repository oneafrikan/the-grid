## Purpose

Keep every generated harness artefact true to its single source and to the vendor's documented format, so that generated copies cannot drift unnoticed.

## ADDED Requirements

### Requirement: Goldens cover every harness target

Every `compose.py` target added by this change SHALL be listed in the `workflow-upgrades` golden script and have a committed golden tree built from the shared fixtures. That fixture set MUST include a specialist with a tool allowlist.

#### Scenario: Emitter change without golden update fails
- **WHEN** the `codex`, `opencode`, `gemini-cli` or `portable` output changes by one byte and the golden is not updated
- **THEN** `scripts/compose-goldens.sh --check` exits 1 and names the file

#### Scenario: Allowlist mapping is pinned
- **WHEN** the goldens are generated
- **THEN** the read-only fixture role's Codex, OpenCode and Gemini files carry the mapped restriction, and the unrestricted role's files carry none

#### Scenario: Stale output is removed
- **WHEN** a stray file is placed in a `_<target>/` output dir and the target is recomposed
- **THEN** the stray file is gone

### Requirement: Format validators and sandboxed tests

The test suite SHALL check every generated agent file and every skill linked into the shared directory against its harness's documented format. It MUST NOT read or write the real home directory.

#### Scenario: Codex TOML round-trips
- **WHEN** a body containing a backslash, a triple quote, a tab and non-ASCII text is written as `developer_instructions`
- **THEN** the file parses with `tomllib` and the value equals the original body

#### Scenario: Shared-dir skill limits enforced
- **WHEN** a skill is linked into the shared directory
- **THEN** its name matches `^[a-z0-9]+(-[a-z0-9]+)*$`, it equals the directory name, and its description is 1 to 1024 characters

#### Scenario: Unmapped tool fails closed
- **WHEN** a role's allowlist names a tool with no Gemini mapping
- **THEN** compose exits 1 with `E_TOOL_UNMAPPED` naming the role and tool, and writes no output directory
