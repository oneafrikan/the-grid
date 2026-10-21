# Changelog

All notable changes to this project are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

- Added: skill, agent and role counts in the README and site are generated from `SKILLS.md` and the agent examples instead of typed by hand, with a gate check for drift.
- Added: `INSTALL.md`, `CONTRIBUTING.md`, `docs/architecture.md`, `docs/roadmap.md` and `docs/private-projects.md`, split out of the README and `BOOTSTRAP.md`, with drift-guard tests.
- Added: `SECURITY.md` (what the scripts write, private vulnerability reporting, supported versions) and this changelog.
- Added: `scripts/repo-metadata.sh` (checks the GitHub repo description and topics) and `scripts/build-site-assets.sh` (favicon and site assets).
- Planned: a README translation pipeline; it does not exist yet.
