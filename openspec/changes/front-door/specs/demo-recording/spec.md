## Purpose

Provide a reproducible terminal demo of install to first use, so the proof asset can be re-recorded rather than hand-captured.

## ADDED Requirements

### Requirement: Reproducible demo tape
The repository SHALL include `docs/demo/demo.tape` for charmbracelet vhs that records bootstrap with agents followed by `/tron`, with a total visible sleep of at most 20 seconds and no absolute user paths.

#### Scenario: Tape content
- **WHEN** the tape is parsed by the demo test
- **THEN** it has an Output .gif line, Require git and Require claude lines, the `bootstrap.sh --with-agents` command and `/tron`
- **AND** the sum of Sleep values is at most 20 seconds

### Requirement: Rendered artefact is bounded
A rendered `docs/demo/bootstrap-to-tron.gif` SHALL be at most 3 MB and SHALL be embedded in README.md only after it exists; index.html SHALL carry a text link to it and no embedded copy.

#### Scenario: Reference matches file
- **WHEN** README.md embeds the GIF
- **THEN** the file exists and is at most 3 MB
- **AND** index.html contains no `<img>` of the GIF
