## Purpose

Collect aggregated, privacy-safe usage counts per machine from agent-harness logs, through an adapter seam, so pruning decisions rest on evidence that outlives transcript retention.

## ADDED Requirements

### Requirement: Harness-aware extraction behind an adapter contract
The system SHALL read usage through adapters that implement availability detection, normalised event emission and a wired-set listing, with the Claude Code adapter shipped and other harnesses addable by one module and one registry entry.

#### Scenario: Claude Code events counted
- **WHEN** transcripts contain skill tool calls, subagent tool calls and slash commands across several days
- **THEN** the output holds per-day counts for skills, agents and slash commands

#### Scenario: Extra harness needs no extractor change
- **WHEN** a fake adapter is added to the registry
- **THEN** its counts appear under its own harness key without changes to the extractor

#### Scenario: No adapter available
- **WHEN** no adapter finds its logs
- **THEN** the extractor exits successfully after printing that no adapters are available

### Requirement: Aggregated counts only
The output MUST contain only counts keyed by skill, agent or slash-command name, per-day token totals keyed by model name, per-day hook-fire counts keyed by hook name, dates, listing sizes and the wired-name lists, and MUST NOT contain prompt text, file paths, project names, session identifiers or message identifiers.

#### Scenario: Prompt text never stored
- **WHEN** a transcript prompt contains a distinctive marker string
- **THEN** the marker does not appear anywhere in the output file

#### Scenario: Path-like slash text rejected
- **WHEN** a user message starts with a file path or a bare word after a slash
- **THEN** it is not recorded as a slash command

#### Scenario: Command tag inside prose rejected
- **WHEN** a user message mentions a command-name tag in the middle of ordinary text
- **THEN** it is not recorded as a slash command

### Requirement: Token totals deduplicated by message
The extractor SHALL record input, output, cache-read and cache-write token totals and a message count per day and model, counting each message identifier once across all transcript files and taking, for a message streamed in several records, the largest value of each field.

#### Scenario: Streamed message counted once
- **WHEN** one message appears in two records with output tokens 8 and 680
- **THEN** the day's total for that model includes 680 output tokens for that message and one message

#### Scenario: Copied history adds nothing
- **WHEN** a transcript file is copied into a second file with the same identifiers and timestamps
- **THEN** token, skill, agent and slash counts are the same as with one file

#### Scenario: Synthetic and unidentified records excluded
- **WHEN** a usage record has a synthetic model name or no message identifier
- **THEN** it contributes no tokens

### Requirement: Hook fires counted by name
The extractor SHALL count hook fires per day keyed by hook name, counting each transcript record once across all files, and MUST NOT store hook commands, outputs or tool identifiers.

#### Scenario: Hook fires counted
- **WHEN** transcripts contain hook success and error records for the same hook name
- **THEN** the day's count for that name includes both, and a copied record adds nothing

#### Scenario: Hook command never stored
- **WHEN** a hook record carries a command containing a distinctive path
- **THEN** the path does not appear in the output file

### Requirement: Idempotent retention-safe merge
Repeated extraction SHALL merge into the existing per-host file by taking, for each day and key, the larger of the stored and newly scanned count, leaving days outside the scan untouched.

#### Scenario: Second run changes nothing
- **WHEN** the extractor runs twice on the same transcripts
- **THEN** the output file is byte-identical after the second run

#### Scenario: Expired transcripts do not erase history
- **WHEN** the oldest day's transcripts are deleted and the extractor runs again
- **THEN** that day's stored counts and token totals remain

#### Scenario: Corrupt existing file is not overwritten
- **WHEN** the existing per-host file cannot be parsed
- **THEN** the extractor exits non-zero and leaves the file unchanged

#### Scenario: Unsafe output refused
- **WHEN** the host name is empty or localhost, or the output directory is inside the repository
- **THEN** the extractor exits non-zero and writes nothing

### Requirement: Format-drift warning
The extractor SHALL print a warning, without failing, when a scan read lines but recognised no assistant records, or when more than five percent of lines were unparseable.

#### Scenario: Unrecognised format warned
- **WHEN** transcripts contain valid JSON lines but no assistant records
- **THEN** a one-line warning that the transcript format may have changed is printed and the exit status is zero

### Requirement: Retention guidance
The extractor SHALL warn, without changing any settings, when the harness retention setting is unset or below 45 days, and the documentation MUST recommend 60 days.

#### Scenario: Short retention warned
- **WHEN** the retention setting is missing or 30
- **THEN** a one-line warning recommending 60 is printed

#### Scenario: Adequate retention is silent
- **WHEN** the retention setting is 60
- **THEN** no warning is printed
