## Purpose

Turn cross-machine usage evidence into numbered, reversible proposals to demote unused wired skills, leaving every decision and every edit to the maintainer.

## ADDED Requirements

### Requirement: Cross-host aggregation
The aggregator SHALL sum usage across all host files in the usage directory over a window, report host count and day coverage, and ignore files with an unknown schema version.

#### Scenario: Two hosts summed
- **WHEN** two host files each record uses of different skills
- **THEN** the totals include both and the host count is two

#### Scenario: Unknown schema ignored
- **WHEN** a file declares a schema version the aggregator does not know
- **THEN** it is skipped without failing the run

#### Scenario: Unparseable file ignored
- **WHEN** a file in the usage directory is not valid JSON
- **THEN** it is skipped, named as ignored, and the run does not fail

#### Scenario: Token totals summed by month
- **WHEN** two host files record token totals for the same model and month
- **THEN** the aggregate holds their sum for that month and model

### Requirement: Read-only prune proposals
The prune report MUST write nothing except its own output and SHALL list proposals to move low-use baseline skills to library or set them to name-only, ordered by characters saved and numbered for reply.

#### Scenario: Unused repo proposed for demotion
- **WHEN** at least 90 percent of a baseline repo's wired skills have no uses in the window
- **THEN** the report proposes moving that repo to library, naming any used skills to keep

#### Scenario: Rarely used skill gets name-only
- **WHEN** a skill has between one and the rare-threshold uses across all hosts
- **THEN** the report lists it with its characters saved and a valid skill-overrides JSON block

#### Scenario: Skill used on one host is not proposed
- **WHEN** a skill has uses on one host and none on another
- **THEN** it is not proposed for demotion

#### Scenario: Token and hook data do not affect proposals
- **WHEN** token totals and hook counts are removed from every host file
- **THEN** the report text and proposals are unchanged

#### Scenario: No file is modified
- **WHEN** the report runs against a mock grid, settings file and usage directory
- **THEN** their contents are identical before and after

### Requirement: Evidence thresholds and keep list
The report MUST refuse to propose anything when usage coverage is under the minimum days, and MUST never propose names on the tracked keep list.

#### Scenario: Insufficient history
- **WHEN** coverage is below the minimum days
- **THEN** the report states the shortfall and lists no proposals

#### Scenario: Keep list honoured
- **WHEN** an unused skill is on the keep list
- **THEN** it does not appear in any proposal

### Requirement: Unused agent listing
The report SHALL list wired agents with zero uses across all hosts together with their project gate, without a savings figure.

#### Scenario: Unused agent listed
- **WHEN** an agent appears in a host's wired list but never in usage
- **THEN** it is listed with the project overlay entry that would remove it
