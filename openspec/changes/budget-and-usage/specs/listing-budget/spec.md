## Purpose

Keep the size of the skill and agent description listing that harnesses load every session measured and bounded, so growth is a visible, reviewed decision rather than silent truncation.

## ADDED Requirements

### Requirement: Description size measurement
The system SHALL report the total description characters of owned skills, composed role descriptions and, where a baseline exists, the baseline wired set, counting each entry as its name plus its description cut at 1,536 characters plus a fixed overhead.

#### Scenario: Long description is cut at the entry limit
- **WHEN** a skill description of 2,000 characters is measured
- **THEN** it contributes 1,536 characters plus its name length plus the fixed overhead to the total

#### Scenario: Machine overlay does not change the baseline figure
- **WHEN** a machine overlay adds or subtracts wired skills
- **THEN** the baseline total is identical to the total without the overlay

#### Scenario: Private roles are excluded
- **WHEN** private roles exist on the machine
- **THEN** they are not counted in any scope

### Requirement: Budget ratchet in the commit gate
The commit gate MUST fail when any measured total exceeds its value in the committed budget target file.

#### Scenario: Regression fails the gate
- **WHEN** an owned skill description grows so the owned total exceeds its target
- **THEN** the budget check exits non-zero and the gate reports FAIL for budget

#### Scenario: Baseline scope skipped without a baseline
- **WHEN** the machine has no baseline manifest or has uninitialised submodules
- **THEN** the owned scope is still enforced and the baseline scope is reported as skipped without failing the gate

#### Scenario: Targets only go down by default
- **WHEN** the target update command would raise a number
- **THEN** it refuses unless explicitly told to allow raising

### Requirement: Per-entry limit for owned descriptions
The system MUST fail the budget check when an owned skill or role description exceeds 180 characters or spans more than one line.

#### Scenario: Overlong owned description
- **WHEN** a root skill has a 250-character description
- **THEN** the check fails and names the file
