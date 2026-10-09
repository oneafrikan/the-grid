## Purpose

Define which rule packs the-grid ships, how they are authored from community consensus, and the constraints that keep ECC's house opinions and always-on cost out.

## ADDED Requirements

### Requirement: Shipped pack set
The repository SHALL contain tier 1 packs `sql`, `dbt`, `bash`, `terraform`, `django`, `flask`, `laravel`, `wordpress` and tier 2 packs `python`, `typescript`, `web`, `react`, `vue`, `php`, `ruby`, `golang`, `rust` under `rules/`, every rule file path-scoped, with no common or always-on layer and no Claude Code hook advice or design-taste policy.

#### Scenario: Inventory
- **WHEN** `python3 scripts/rules.py list` runs
- **THEN** all seventeen packs are listed with their tier, file counts and byte sizes

#### Scenario: Attribution and opinions clean
- **WHEN** `rules.py lint` runs on the tree
- **THEN** it reports no finding, including no `E_ATTRIBUTION`, `E_OPINION` or `E_PATHS`

#### Scenario: No hooks advice
- **WHEN** the pack directories are listed
- **THEN** no pack contains a file describing Claude Code hooks; the React pack's `hooks.md` covers React hooks only

### Requirement: Sourced, reviewed packs that stack stubs point to
Each pack PR MUST carry a source-fidelity review and an opinion/overbuild review with all must-fix items resolved, and each `agent-factory/stacks/*/stack.yaml` stub SHALL carry a comment naming its rule packs, with `docs/rules.md` documenting the mapping.

#### Scenario: Two reviews attached
- **WHEN** a content PR is marked ready
- **THEN** its body contains a Reviewer A (source fidelity) section and a Reviewer B (opinion and overbuild) section with all must-fix items resolved

#### Scenario: Stub points to packs
- **WHEN** `agent-factory/stacks/lamp/stack.yaml` is read
- **THEN** a comment names the `php`, `sql` and `bash` packs and its keys are unchanged
