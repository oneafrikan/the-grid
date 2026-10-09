## Purpose

Let composed agents be rendered with no install-specific identity, so output destined for a public tree is reproducible and free of personal data.

## ADDED Requirements

### Requirement: Neutral identity switch

`agent-factory/compose.py` SHALL, when `GRID_NEUTRAL_IDENTITY=1` is set, render the IDENTITY nameplate with the placeholder `(not set)` for operator, channels and machine regardless of `user.yaml` or the local hostname.

#### Scenario: Configured install, neutral mode
- **WHEN** the file named by `GRID_USER_CONFIG` sets `operator: "A <a@example.com>"` and compose runs with `GRID_NEUTRAL_IDENTITY=1`
- **THEN** no composed file contains `a@example.com` or the local hostname

#### Scenario: Default behaviour unchanged
- **WHEN** compose runs without `GRID_NEUTRAL_IDENTITY`
- **THEN** output is byte-identical to before this change, including the hostname fallback for `machine`
