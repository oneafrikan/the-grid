## Purpose

Owned skills and composed roles expose a one-line listing description and keep long procedures out of the always-loaded text, so they cost little unless used.

## ADDED Requirements

### Requirement: One-line descriptions
Every owned skill and every public role SHALL have a single-line description of at most 180 characters, with trigger phrases kept in the body under a heading named When to invoke.

#### Scenario: Triggers move to the body
- **WHEN** a skill formerly listed trigger phrases in its description
- **THEN** the description has no trigger list and the phrases appear verbatim under a When to invoke heading in the body

#### Scenario: Role description is emitted verbatim
- **WHEN** a role defines a description in its role file
- **THEN** the composed subagent or skill carries exactly that description with no appended invocation text

#### Scenario: Role without a description keeps the old output
- **WHEN** a role (for example a private role) defines no description
- **THEN** its composed description is the same as before this change

### Requirement: On-demand sections for long skills
An owned skill whose main file exceeds 4,000 bytes MUST keep only its purpose, invocation guidance, step outline and a Sections index in the main file, with reference material in files under a sections directory that are read only when their stated condition applies.

#### Scenario: Section integrity
- **WHEN** a skill has a sections directory
- **THEN** every section file is listed in the Sections index and every listed file exists and is at most 6,000 bytes

#### Scenario: Sections travel with the wired skill
- **WHEN** the skill is wired into a skills directory
- **THEN** its section files are readable through the wired link

#### Scenario: Split preserves content
- **WHEN** a skill is split
- **THEN** every non-blank line of the former main file appears in the new main file or a section, apart from the added index, invocation heading and description change
