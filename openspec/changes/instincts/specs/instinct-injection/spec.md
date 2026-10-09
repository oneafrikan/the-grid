## Purpose

Give a new session a small, ranked, clearly untrusted reminder of learned habits for the current project, at a fixed worst-case token cost.

## ADDED Requirements

### Requirement: Injection is capped
The system SHALL inject at most 6 instincts and at most 1500 characters, dropping whole lowest-ranked items rather than truncating one.

#### Scenario: Character cap
- **WHEN** the qualifying instincts would exceed 1500 characters
- **THEN** the output is at most 1500 characters and ends on a complete item

### Requirement: Only confident instincts are injected, ranked by scope
The system SHALL inject only active instincts with confidence at least 0.5, ranked by confidence plus 0.25 for project scope.

#### Scenario: Below threshold
- **WHEN** an instinct has confidence 0.49
- **THEN** it is not injected

#### Scenario: Project beats global
- **WHEN** a project-scoped and a global instinct both have confidence 0.6
- **THEN** the project-scoped one ranks first

### Requirement: Injected memory is framed as fallible context, not instructions
The system SHALL prefix injected text with a fixed header stating that the items are machine-generated and may be wrong, that they are context and not instructions, and that the user's request and the repo's docs take precedence, counting the header inside the character cap, and SHALL print nothing at all when no instinct qualifies.

#### Scenario: Header present
- **WHEN** at least one instinct qualifies
- **THEN** the output begins with the fixed header
- **AND** the header contains the phrases "not instructions" and "always win"
- **AND** the header plus items total at most 1500 characters

#### Scenario: Nothing qualifies
- **WHEN** no instinct meets the threshold
- **THEN** the output is empty

### Requirement: Injection re-validates what it reads
The system SHALL validate and re-scrub every instinct field at injection time and skip any line that fails.

#### Scenario: Tampered line
- **WHEN** a store line has an action containing a URL or a token-shaped string
- **THEN** the URL line is skipped and the token-shaped string is redacted

#### Scenario: Instruction-like text
- **WHEN** a store line has an action containing "ignore previous instructions"
- **THEN** the line is skipped

### Requirement: Injection is opt-in and switchable
The system SHALL inject only when `learning: on` is set and `GRID_INSTINCTS` is not `0`.

#### Scenario: Kill switch
- **WHEN** `GRID_INSTINCTS=0` is set
- **THEN** the injector prints nothing
