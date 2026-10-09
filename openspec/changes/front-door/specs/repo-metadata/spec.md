## Purpose

Keep the GitHub About text, homepage and topics reproducible and checkable instead of hand-edited in a settings page.

## ADDED Requirements

### Requirement: Declared metadata
scripts/repo-metadata.sh SHALL declare the About description, the homepage URL and exactly nine topics: claude-code, claude-skills, claude-code-skills, agent-skills, ai-agents, dotfiles, subagents, skills-manager, developer-tools.

#### Scenario: Values
- **WHEN** the script's declared values are printed
- **THEN** the description is at most 350 characters, the homepage is the Pages URL, and the topic list equals the nine above

### Requirement: Read-only check by default
The script SHALL default to `--check`, SHALL compare declared values with `gh repo view` output, and SHALL exit 1 with a diff on drift without changing anything.

#### Scenario: Drift
- **WHEN** a stub gh returns a different topic list
- **THEN** the script prints the difference and exits 1 and makes no `repo edit` call

### Requirement: Explicit apply
The script SHALL change GitHub state only when `--apply` is passed, using `gh repo edit` to set description, homepage and the topic difference.

#### Scenario: Apply
- **WHEN** `--apply` runs against a stub gh with drift
- **THEN** the stub receives `repo edit` calls that set the description and homepage and add or remove the differing topics

### Requirement: Conservative topic claims
The topic list SHALL NOT include a harness (codex, gemini-cli, opencode) until that harness has a shipped emitter.

#### Scenario: No premature topics
- **WHEN** the declared topics are listed
- **THEN** none of codex, gemini-cli or opencode is present
