## Why

Wired skills, agents and hooks run with the user's full shell and file access, and the-grid pulls most of them from third-party repos. Snyk's February 2026 scan of 3,984 public skills found 76 confirmed malicious payloads and 13.4% with a critical issue (vendor-sourced figures). Today nothing in the-grid checks wired content for pipe-to-shell installs, unpinned `npx -y`, credential shapes, hidden Unicode or prompt-injection text, and nothing records why a source is trusted or a skill was left out.

## What Changes

- Add `policy.yaml` (tracked): allowed source repos, banned-pattern rules with severities, file-class globs.
- Add `scripts/audit.py` (Python stdlib) plus `scripts/lib/miniyaml.py` (restricted-YAML reader) and `scripts/audit.sh` (selects `--wired`, `--owned` or `--gate` directory sets). The scanner takes an explicit list of directories, so manifest-lock-install (workstream 3) can call it on staged content.
- Add `CURATION.md` (tracked): one section per trusted wired source saying why, the exclusion list with reasons, and the audit allowlist (a fenced `audit-allow` block; every entry needs a reason).
- `scripts/wire.sh` runs the audit before it touches any link and exits 3 on a high finding; `GRID_AUDIT=warn` demotes that to a warning.
- `scripts/gate.sh` gains an `audit` check (owned assets always; wired set when this machine has a baseline).
- Bats tests build fixture skills at test time: ones that must be flagged and ones that must pass.

## Capabilities

### New

- `skill-vetting`: policy-driven static scan of skill, agent, rule and hook directories with a file:line report, severities, context downgrades and a justified allowlist.
- `source-curation`: allowed-source enforcement for wired repos and a curation record covering every wired source.
- `audit-integration`: the audit runs in `wire.sh` and `gate.sh` and blocks on high severity.

### Modified

- None. `openspec/specs/` is empty; this change adds the first specs.

## Impact

- New files: `policy.yaml`, `CURATION.md`, `scripts/audit.py`, `scripts/audit.sh`, `scripts/lib/miniyaml.py`, `tests/test_miniyaml.bats`, `tests/test_audit.bats`, `tests/test_audit_sources.bats`, `tests/test_audit_integration.bats`, `tests/test_curation.bats`.
- Edited: `scripts/wire.sh` (pre-link audit step), `scripts/gate.sh` (new check), `CLAUDE.md` (key files, wire.sh contract).
- Cost: roughly 10 s added to a wire run on a 160-skill machine (measured on an unoptimised prototype); no network, no model calls, no tokens.
- Use case: protect every machine and harness from malicious or careless upstream content across all stacks (web/app, marketing, data engineering); no new asset type is introduced.
- Interacts with workstream 3 (`manifest-lock-install`): it calls `audit.py` on staged directories before linking. This change does not depend on `grid.lock`.

## Non-goals

- No LLM-based or semantic review of skills, and no model calls (a deterministic tripwire, not a guarantee).
- No runtime sandboxing or egress filtering of skills once wired.
- No multi-line or AST analysis; the scan is line-based and says so.
- No URL-host allowlist for documentation links (ECC's pi-core scan does this; too noisy here).
- No sha/content-hash pinning or drift detection (workstream 3 owns `grid.lock`).
- No `grid` binary and no `grid audit` subcommand wiring (workstream 3 owns the CLI; it shells out to `scripts/audit.sh` / `scripts/audit.py`).
- No scanning of composed output under `agent-factory/projects/` as a separate set; it is covered through the wired dry run.
- No auto-fix, no quarantine, no automatic removal of flagged skills.
