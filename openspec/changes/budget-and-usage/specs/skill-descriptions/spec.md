## Purpose

Owned skills and composed roles expose a short, trigger-bearing listing description and keep long procedures out of the always-loaded text, so they cost little unless used and are still selected when relevant.

## ADDED Requirements

### Requirement: Short descriptions that keep triggers
Every listed owned skill and every public role SHALL have a single-line description of at most 250 characters that states what it does and keeps its key trigger phrases.

#### Scenario: Triggers stay in the description
- **WHEN** a skill description is shortened
- **THEN** its strongest trigger phrases remain in the description and the redundant slash-command mention is removed

#### Scenario: Role description is emitted verbatim
- **WHEN** a role defines a description in its role file
- **THEN** the composed subagent or skill carries exactly that description with no appended invocation text

#### Scenario: Role without a description keeps the old output
- **WHEN** a role (for example a private role) defines no description
- **THEN** its composed description is the same as before this change

### Requirement: On-demand sections for long skills
An owned skill whose main file exceeds 4,000 bytes MUST keep only its purpose, step outline and a Sections index in the main file, with reference material in files under a sections directory that are read only when their stated condition applies.

#### Scenario: Section integrity
- **WHEN** a skill has a sections directory
- **THEN** every section file is listed in the Sections index and every listed file exists and is at most 6,000 bytes

#### Scenario: Sections travel with the wired skill
- **WHEN** the skill is wired into a skills directory
- **THEN** its section files are readable through the wired link

#### Scenario: Split preserves content
- **WHEN** a skill is split
- **THEN** every non-blank line of the former main file appears in the new main file or a section, apart from the added index
