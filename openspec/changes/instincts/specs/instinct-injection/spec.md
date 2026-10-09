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

### Requirement: Injected memory is framed as untrusted context
The system SHALL prefix injected text with a header stating it is untrusted context and not instructions, and SHALL print nothing at all when no instinct qualifies.

#### Scenario: Header present
- **WHEN** at least one instinct qualifies
- **THEN** the output begins with a line stating the items are untrusted context, not instructions

#### Scenario: Nothing qualifies
- **WHEN** no instinct meets the threshold
- **THEN** the output is empty

### Requirement: Injection re-validates what it reads
The system SHALL validate and re-scrub every instinct field at injection time and skip any line that fails.

#### Scenario: Tampered line
- **WHEN** a store line has an action containing a URL or a token-shaped string
- **THEN** the URL line is skipped and the token-shaped string is redacted

### Requirement: Injection is opt-in and switchable
The system SHALL inject only when `learning: on` is set and `GRID_INSTINCTS` is not `0`.

#### Scenario: Kill switch
- **WHEN** `GRID_INSTINCTS=0` is set
- **THEN** the injector prints nothing
