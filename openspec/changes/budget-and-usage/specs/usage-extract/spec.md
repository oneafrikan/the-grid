## Purpose

Collect aggregated, privacy-safe usage counts per machine from agent-harness logs, through an adapter seam, so pruning decisions rest on evidence that outlives transcript retention.

## ADDED Requirements

### Requirement: Harness-aware extraction behind an adapter contract
The system SHALL read usage through adapters that implement availability detection, normalised event emission and a wired-set listing, with the Claude Code adapter shipped and other harnesses addable by one module and one registry entry.

#### Scenario: Claude Code events counted
- **WHEN** transcripts contain skill tool calls, subagent tool calls, slash commands and assistant token usage across several days
- **THEN** the output holds per-day counts for skills, agents, slash commands and tokens by model

#### Scenario: Streamed duplicate messages counted once
- **WHEN** the same assistant message id appears several times in a transcript
- **THEN** its tokens are counted once

#### Scenario: Extra harness needs no extractor change
- **WHEN** a fake adapter is added to the registry
- **THEN** its counts appear under its own harness key without changes to the extractor

#### Scenario: No adapter available
- **WHEN** no adapter finds its logs
- **THEN** the extractor exits successfully after printing that no adapters are available

### Requirement: Aggregated counts only
The output MUST contain only counts keyed by skill, agent, slash-command or model name, dates and the wired-name lists, and MUST NOT contain prompt text, file paths, project names or session identifiers.

#### Scenario: Prompt text never stored
- **WHEN** a transcript prompt contains a distinctive marker string
- **THEN** the marker does not appear anywhere in the output file

#### Scenario: Path-like slash text rejected
- **WHEN** a user message starts with a file path
- **THEN** it is not recorded as a slash command

### Requirement: Idempotent retention-safe merge
Repeated extraction SHALL merge into the existing per-host file by taking, for each day and key, the larger of the stored and newly scanned count, leaving days outside the scan untouched.

#### Scenario: Second run changes nothing
- **WHEN** the extractor runs twice on the same transcripts
- **THEN** the output file is byte-identical after the second run

#### Scenario: Expired transcripts do not erase history
- **WHEN** the oldest day's transcripts are deleted and the extractor runs again
- **THEN** that day's stored counts remain

### Requirement: Retention guidance
The extractor SHALL warn, without changing any settings, when the harness retention setting is unset or below 45 days, and the documentation MUST recommend 60 days.

#### Scenario: Short retention warned
- **WHEN** the retention setting is missing or 30
- **THEN** a one-line warning recommending 60 is printed

#### Scenario: Adequate retention is silent
- **WHEN** the retention setting is 60
- **THEN** no warning is printed
