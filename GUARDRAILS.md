# Guardrails
<!-- DRAFT: derived from openspec/config.yaml and CLAUDE.md only; pending the operator's review. -->

Read before editing, committing or opening a PR. One must-not per line.

Format: a line starting with a dash, an ID `G<n>`, the must-not, then `[check: human|CI|hook|none]` with an optional `: <how>` before the closing bracket. IDs are never reused or renumbered; a withdrawn guardrail keeps its ID and reads `(retired)`. Cite one as `GUARDRAILS#G4`.

- G1: Commit personal data (names, emails, hostnames, home paths, tokens) to this public repo [check: CI: scripts/check-personal.sh]
- G2: Hand-edit a generated file (`SKILLS.md`, `docs/SOURCES.md`, `MAP.md`, composed output) [check: CI: scripts/catalog.sh --check, scripts/map.py --check]
- G3: Add sponsored content or a paid-product dependency [check: human]
- G4: Add a new asset type or pack with no named use case [check: human]
- G5: Let a test touch the real `~/.claude` [check: human: bats helpers point every target at a temp dir]
- G6: Commit a line that looks like a secret [check: hook: hooks/scripts/pre-bash-secret-scan.sh, opt-in (profile standard; not enabled by default here)]
- G7: Merge a change to canon files without a human [check: none]
