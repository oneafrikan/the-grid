## Purpose

Define which rule packs the-grid ships, how they are authored from community consensus, and the constraints that keep ECC's house opinions and always-on cost out.

## ADDED Requirements

### Requirement: Tier 1 packs exist
The repository SHALL contain written-from-scratch packs `sql`, `dbt`, `bash`, `terraform`, `django`, `flask`, `laravel` and `wordpress` under `rules/`, each with `pack.yaml` of `tier: 1`.

#### Scenario: Inventory
- **WHEN** `python3 scripts/rules.py list` runs
- **THEN** the eight tier 1 packs are listed with their file counts and byte sizes

### Requirement: Tier 2 packs exist and are attributed
The repository SHALL contain packs `python`, `typescript`, `web`, `react`, `vue`, `php`, `ruby`, `golang` and `rust` adapted from `repos/ecc/rules/` with `tier: 2`, ECC attribution, and no ECC house opinions.

#### Scenario: Attribution complete
- **WHEN** `rules.py lint` runs on the tree
- **THEN** it reports no `E_ATTRIBUTION` or `E_OPINION` finding for any tier 2 pack

### Requirement: No always-on rules
Every shipped rule file MUST be path-scoped; the repository SHALL NOT ship a common or universal rule layer.

#### Scenario: No catch-all scopes
- **WHEN** lint runs on the tree
- **THEN** no rule file has an empty or catch-all `paths` scope

### Requirement: Claude Code hook advice excluded
Packs MUST NOT contain Claude Code hook configuration advice (ECC `hooks.md` content) or design-taste policy (ECC `web/design-quality.md`).

#### Scenario: No hooks files
- **WHEN** the pack directories are listed
- **THEN** no pack contains a `hooks.md` that describes Claude Code hooks, except the React pack's `hooks.md`, which covers React hooks

### Requirement: Pack content is community-sourced and doubly reviewed
Each pack README SHALL cite community or vendor documentation per rule file, and each pack PR MUST carry the outputs of a source-fidelity review and an opinion/overbuild review.

#### Scenario: Sources present
- **WHEN** lint runs on a content PR
- **THEN** every rule file has a Sources row with an https URL

#### Scenario: Two reviews attached
- **WHEN** a content PR is marked ready
- **THEN** its body contains a Reviewer A (source fidelity) section and a Reviewer B (opinion and overbuild) section with all must-fix items resolved

### Requirement: Stack overlays defer to rule packs
The `agent-factory/stacks/*/stack.yaml` stubs SHALL name the rule packs that carry each stack's conventions, and `docs/rules.md` MUST document the mapping.

#### Scenario: Stub points to packs
- **WHEN** `agent-factory/stacks/lamp/stack.yaml` is read
- **THEN** a comment names the `php`, `sql` and `bash` packs and its keys are unchanged
