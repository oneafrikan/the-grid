## Purpose

Publish the static landing page without Jekyll processing the repository's submodule trees.

## ADDED Requirements

### Requirement: Pages publishes static files without Jekyll
The repository root SHALL contain an empty `.nojekyll` file so the Pages build for `main` finishes with status `built` and the site answers HTTP 200.

#### Scenario: Marker present
- **WHEN** the test suite runs
- **THEN** `.nojekyll` exists at the repo root

#### Scenario: Post-merge check
- **WHEN** the change is merged to `main`
- **THEN** the latest Pages build status is `built`
- **AND** a HEAD request to the site URL returns 200

#### Scenario: Marker is not enough
- **WHEN** the first build after merge still errors or exceeds the Pages size limit
- **THEN** a follow-up issue to deploy via Actions is opened and this change is not reopened
