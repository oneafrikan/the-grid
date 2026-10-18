## Context

Verified in this worktree (branch `spec/epistemics-and-loop`, cut from `next` at 05b23d4):

- `project-factory/scripts/cut-project.sh` copies `templates/_common/` then `templates/<t>/` with one rule: copy if absent, skip and report if present and different. It cannot merge text into an existing file. All four templates have their own `CLAUDE.md` (27-47 lines), so a `CLAUDE.md` in `_common` would collide with them and be SKIPPED in seed mode.
- `_common` today: `AGENTS-SETUP.md`, `CONTEXT.md`, `LEARNINGS.md`, `SPECS.md`, `handoffs/`, `prompts/`, `.grid/project.yaml`, `.claude/skills/project-review/`. No `PURPOSE.md`, `GUARDRAILS.md`, `BEHAVIOUR.md`, `MAP.md`, `signals/`, `knowledge/` anywhere in the repo.
- `agent-factory/_core/AGENTS_base.md` is 2907 bytes. It has "Spec-Driven Repos (OpenSpec)" (the SPECS.md boot-check precedent) and "Signal Protocol (handoff)" using `signals/→<agent>.md`; 27 role `AGENTS.md` files and `agents_base.yaml` and `compose.py:741` repeat that path. The 4096-byte cap (`compose.py` `AGENTS_MAX_BYTES`, 5120 for orchestrators) is checked against the role's own `AGENTS.md`, not the merged text.
- `scripts/catalog.sh --check` exits 0 current, 1 stale, 2 check failed. `scripts/gate.sh` runs named checks and lists them in its header; `pysyntax` already parses every tracked `*.py`.
- Instincts inject at most 6 items (`scripts/instincts/inject.py:14,81`), opt-in via `learning: on` in `.grid/project.yaml`.
- **Lean deploys do not get `AGENTS_base.md`.** `compose.py` lean profile (lines 662-677, `render_lean_body`) keeps only the role's own `AGENTS.md` sections and drops `_core` base scaffolding and the signal-file handoff protocol; it also appends "Signal-file hand-offs (`signals/`) do not apply" (`compose.py:741`). `agent-factory/deploy.py` (per-project agents, `.claude/agents/grid-<role>.md`) is the lean path. So the vocabulary in `AGENTS_base.md` reaches full-profile agents (globally wired grid agents) but not lean project agents. `compose.py` may not change here, so the project route is `CLAUDE.md` trailhead -> `signals/README.md`.
- Compose configs list roles as `- role: <name>` with optional `delegates_to:` (inline list or block list) in `agent-factory/examples/{core,grid,finance-desk,learning-desk}.yaml`; 38 role dirs under `agent-factory/roles/`; 14 root skills under `skills/`.
- No `CODEOWNERS` (`.github/` holds `dependabot.yml`, `pull_request_template.md`, `workflows/`). Relevant to A3 only.
- `scripts/check-personal.sh` scans every tracked file, so charter files in the public repo must pass it.

## Decisions

- Decided: charter files live at repo root; `scripts/map.py` is the generator (brief).
- Decided: `PURPOSE.md` has exactly three `##` headings (Problem, Intended solution, Outcome) plus one line `Must-nots: see [GUARDRAILS.md](GUARDRAILS.md).` No guardrail content inside it. Reason: PURPOSE is read at every session start; guardrails are read only before acting.
- Decided: a guardrail line is `- G<n>: <must-not, one line> [check: human|CI|hook|none]` with an optional `: <how>` inside the brackets, e.g. `[check: CI: scripts/gate.sh]`. IDs are never reused or renumbered; a withdrawn guardrail keeps its ID and reads `- G4: (retired)`. Citable as `GUARDRAILS#G4`.
- Decided: `BEHAVIOUR.md` starts with one line stating that grid-wide defaults live in `agent-factory/_core/AGENTS_base.md` and that this file lists additions only. Empty body (`(none yet)`) is valid.
- Decided: templates ship the files as stubs with `<fill>` markers (same style as `project-review/SKILL.md`). `map.py --check` does not fail on `<fill>`.
- Decided: `signals/README.md` and `knowledge/README.md` are the per-repo convention and are seeded now so A2 only adds behaviour. They state plainly: sweep not built until `knowledge-signals` ships (the template README says "sweep: none configured"); filing is allowed; signals are secret/private to the project's own repo; the public grid's signals are about the grid only.
- Decided: because lean project agents never see `AGENTS_base.md`, the seeded `signals/README.md` restates the six stages and the warrant rule in at most 25 lines, and the trailhead has a fourth bullet pointing at it. This duplicates `## Evidence and Stages`; a bats test asserts both contain the six stage names and the sentence that `wip` is never promoted.
- Decided: `signals/` holds two kinds of file. Knowledge signals: `<UTC timestamp>-<filer>-<hash>.md`. Handoffs: `→<agent>.md` (existing). `map.py status` counts pending signals as `signals/*.md` excluding `README.md` and names starting with `→`.
- Decided (operator D1): `MAP.md` holds no volatile data: no stage counts, no pending-signal counts. Those come from `python3 scripts/map.py status [--root DIR]`, which prints the six stage counts, `invalid: N` when > 0, and the pending-signal count; it writes nothing, is not checked by `--check` or the gate, and exits 0 (2 on an unreadable root). `MAP.md` changes only when charter files, roles, skills, `delegates_to`, the gh-triage sweep heading or `knowledge/canon/` change, so `--check` stays green across signal commits and sweep commits (the sweep writes only `signals/` and non-canon `knowledge/`). Canon one-liners stay: they change only by a human PR, which regenerates MAP.
- Decided: `map.py` reads two frontmatter keys from `knowledge/**/*.md` (not `README.md`): `claim` (canon lines) and `stage` (`status` only). Everything else about entries is A2. A2's `knowledge.py` entry format (`knowledge/canon/K-<hash8>-<slug>.md`, `claim`, `stage`) is compatible; `map.py` stays free of any import from it.
- Decided: one `scripts/map.py` serves the-grid and projects by feature detection (a section whose source directory is absent is omitted). Canonical copy `scripts/map.py`; mirror `project-factory/templates/_common/scripts/map.py`; a bats test asserts `cmp`.
- Decided: trailhead text lives once in `project-factory/trailhead.md` (outside `templates/`, so it is never copied as a file). A test asserts that block, delimited by `<!-- charter-trailhead -->` ... `<!-- /charter-trailhead -->`, is byte-identical in the four template `CLAUDE.md` files and in the-grid `CLAUDE.md`.
- Decided: for a retrofit, `cut-project.sh` never edits `CLAUDE.md`. After the copy it prints `trailhead.md` if the target has a `CLAUDE.md` without the marker. `MAP.md` is NOT shipped in `_common` (a stub is wrong the moment any file differs): it is generated after the copy. `cut-project.sh` runs the target's `scripts/map.py` to create it only when `MAP.md` was not already present and `scripts/map.py` is the seeded copy (written or unchanged this run); a failure is a warning, not an exit-1.
- Decided: MAP.md budget 150 lines, 12 000 bytes, hard failure (exit 2) over budget.
- Decided (operator D12): project templates get only a pre-commit gate for `map.py --check`, no CI job. `_common/.githooks/pre-commit` (executable shim) runs `python3 scripts/map.py --check` when `python3` and the script exist, else prints a one-line skip notice; on failure it prints `run: python3 scripts/map.py` and exits 1. A seed cut sets `core.hooksPath=.githooks` in the new repo; a retrofit never touches git config and prints the one-line command instead. A project's `scripts/gate.sh` is not created.
- Decided (operator D7): this change owns the whole `AGENTS_base.md` block, so `knowledge-signals` does not edit it. Final wording is below. An agent may file any of the four claimable stages (`wip`, `provisional`, `established`, `canonical`) as a proposal; the stage filed is not the outcome, and `canonical`, supersession and contradiction are always decided by a human. `superseded` and `retired` are not claimable stages (A2: invalid in a signal); they are set by a human PR and expressed in a signal through `supersedes`. Signal fields are as `knowledge-signals` defines them: `filed_by`, `claim`, `stage`, `warrant`, `status: pending`, optional `supersedes`, `contradicts`, `confirms` (each `K-<hash8>`), `guardrail` (`GUARDRAILS#Gn`); file name `YYYYMMDDTHHMMSSZ-<filer>-<hash6>.md`; helper `scripts/knowledge.py file` (A2; mirrored into `_common/scripts/` by A2, with its own `cmp` test; this change's `cmp` test covers `map.py` only).
- Decided: AGENTS_base additions are capped at 2000 bytes (operator D7, was 1600). Measured on the real text: the block below is 1670 bytes (`wc -c`), so the file grows by 1671 (block plus one blank-line separator), 2907 to 4578. New headings are `## Evidence and Stages`, `## Memory`, `## Filing a Knowledge Signal`; none exists in any role `AGENTS.md` (grep at build time, since merge unifies shared headings).
- Decided (operator D9): knowledge signals and the existing `signals/→<agent>.md` handoffs coexist in `signals/`; the handoff section is untouched.
- Decided: gate check is named `map` (`python3 scripts/map.py --check`); skipped with a notice and recorded in `SKIPPED` if `python3` or the script is absent, same pattern as `run_shellcheck`.

## GUARDRAILS.md for the-grid (draft; HUMAN approves)

Derived only from rules already stated in `openspec/config.yaml` (non-negotiables) and `CLAUDE.md`. Implementer verifies each check exists before writing `CI`/`hook`; otherwise `human` or `none`.

| ID | Must-not | Source | Check (verify at build) |
|---|---|---|---|
| G1 | Commit personal data to this public repo | config.yaml "Personal data never lands in this public repo" | CI: `scripts/check-personal.sh` in gate |
| G2 | Hand-edit a generated file (`SKILLS.md`, `docs/SOURCES.md`, `MAP.md`, composed output) | CLAUDE.md "SKILLS.md ... Never edit by hand" | CI: `catalog.sh --check`, `map.py --check` |
| G3 | Add sponsored content or a paid-product dependency | config.yaml "Never a paid product" | human |
| G4 | Add a new asset type with no named use case | config.yaml "every new asset type names its use case" | human |
| G5 | Let a test touch the real `~/.claude` | config.yaml "Tests never touch the real ~/.claude" | human (bats helpers set temp dirs) |
| G6 | Commit a line that looks like a secret | hook `hooks/scripts/pre-bash-secret-scan.sh` | hook (profile `standard`; UNVERIFIED on by default for the-grid) |
| G7 | Merge a change to canon files without a human | brief rule; A3 enforces | none until A3 |

## PURPOSE.md for the-grid (draft; HUMAN approves)

Problem: skills, agents and rules for AI assistants are scattered, drift between machines and tools, and cannot be audited. Intended solution: one repo that wires a curated set identically onto every machine and harness, generated from a single source. Outcome: a fresh machine reaches the same wired set with one command; `bash scripts/gate.sh` passes; drift detectors exit 0. Derived from the existing README/CLAUDE.md intro; wording is the operator's.

## map.py contract

```
python3 scripts/map.py [--check] [--root DIR]
python3 scripts/map.py status [--root DIR]
```

- Python 3 stdlib only, valid on 3.8. Reads and writes UTF-8, `\n` newlines, sorts by code point (no locale dependence), no timestamps, no git calls (so output is the same on a dirty tree and on every machine).
- Usage: `map.py [--check] [--root DIR]` or `map.py status [--root DIR]`; any other argument exits 2 before any write. Default root is the parent of `scripts/`. Writes `<root>/MAP.md`. `--check` writes nothing; exit 0 current, 1 stale (prints a short diff header and `run: python3 scripts/map.py`), 2 error (unreadable input, over budget).
- Config parsing is line-based, no YAML library: from `agent-factory/examples/*.yaml` take `- role: NAME` and `delegates_to:` (inline `[a, b]` or following `- x` lines) per entry. A test runs it on all four real configs and compares to `grep -c '^[[:space:]]*- role:'`.

MAP.md layout (fixed order):

```
# MAP
<!-- generated by scripts/map.py - do not edit; run python3 scripts/map.py -->
## Ontology
### Files            | Path | What | Read when |    (only files that exist; fixed registry order)
### Roles            one line per compose config: `grid: a, b, ...`     (omitted without agent-factory/examples)
### Skills           root-owned: a, b, ...; project-local (.claude/skills): ...    (+ pointer to SKILLS.md if present)
### Knowledge        static line: entries live under knowledge/<stage>/, canon under knowledge/canon/; counts: `python3 scripts/map.py status`    (below-canon entries are not listed: token cap)
## Topology
### Delegation       `orchestrator -> a, b` per delegates_to
### Signals          Filing: any agent or human writes one file to signals/ (see signals/README.md).
                     Sweep (a constant of the repo's code, not of its signals): `gh-triage knowledge sweep` if agent-factory/roles/gh-triage/AGENTS.md has that heading, else `none configured`.
## Epistemology
### Canon            - <claim> (knowledge/canon/<file>)   sorted by file name; first 20; then `+N more: knowledge/canon/`
### Memory           always in context / on demand lines (static text, same as AGENTS_base ## Memory)
```

The Files registry (path, what, read-when) is a constant in `map.py`:

| Path | Read when |
|---|---|
| `PURPOSE.md` | session start |
| `MAP.md` | session start |
| `GUARDRAILS.md` | before editing, committing or opening a PR |
| `BEHAVIOUR.md` | before filing a signal or changing how agents work here |
| `CLAUDE.md` | loaded automatically; conventions |
| `CONTEXT.md` | a domain term or structural decision is unclear |
| `LEARNINGS.md` | on demand: debugging, or before repeating a past mistake |
| `SPECS.md` | before proposing or implementing a non-trivial change |
| `openspec/` | before implementing: specs and in-flight changes |
| `SKILLS.md` | choosing a skill (the-grid only) |
| `handoffs/` | resuming earlier work |
| `signals/` | filing a signal |
| `knowledge/` | you need a claim below canon |
| `.grid/project.yaml` | project facts for deployed agents |

A canon line is `claim` from frontmatter, whitespace-collapsed, truncated to 140 characters with `...`; a file with no `claim` uses its first non-empty body line. `status` counts from frontmatter `stage`; a missing or unknown value counts as `invalid` (A3 turns that into a lint failure; here it is only shown, and never in MAP.md).

## AGENTS_base.md additions (verbatim, 1670 bytes)

Inserted after "Spec-Driven Repos (OpenSpec)" and before "Signal Protocol (handoff)". The handoff section is not edited. The block is the file between the fences; the implementer writes it byte for byte and checks `wc -c` is 1670.

```markdown
## Evidence and Stages

Every claim you record or report carries its warrant: what you ran or read, and where.

- **Completion claims** are tagged RAN (executed this session), READ (read, not executed) or UNTESTED. A result you did not see run is READ, not RAN.
- **Knowledge stages:** `wip` (unverified) < `provisional` (warrant given) < `established` (confirmed by a different filer's own warrant) < `canonical` (human-approved via PR). `superseded` and `retired` are end states set by a human.
- The stage you file is a proposal, not the outcome. `canonical`, and anything that supersedes or contradicts an entry, is always decided by a human.
- No warrant means `wip`, and `wip` is never promoted.
- Confidence (H/M/L) and source tier are not stages; put them in the warrant text.

## Memory

- **Always in context:** the learnings summary in CLAUDE.md, up to 6 instincts at session start when `learning: on`, and the canon lines in MAP.md.
- **On demand only:** LEARNINGS.md and `knowledge/` below canon. Read before relying on them; never present unread material as known.

## Filing a Knowledge Signal

Only if the repo has `signals/README.md`; read it first.

1. Write one new file in `signals/`: `<UTC YYYYMMDDTHHMMSSZ>-<filer>-<hash6>.md`, or run `scripts/knowledge.py file`. Never edit it after commit.
2. Frontmatter: `filed_by`, `claim` (one line), `stage` (wip, provisional, established or canonical), `warrant`, `status: pending`. Optional: `supersedes`, `contradicts`, `confirms` (each `K-<hash8>`), `guardrail` (`GUARDRAILS#Gn`).
3. No secrets or personal data. Commit it; only the sweep moves files.
4. Handoffs are different: `signals/→<agent>.md`.
```

This change owns the block. If a later change alters a signal field, it edits this section through a new `charter-files` delta, not in `AGENTS_base.md` alone.

## Trailhead block (verbatim)

```markdown
<!-- charter-trailhead -->
## Start here

- Session start: read `PURPOSE.md` and `MAP.md`.
- Before acting (editing, committing, opening a PR): read `GUARDRAILS.md`.
- Recording a claim or filing a signal: read `signals/README.md` (stages, warrant rule, file format).
- Everything else: find it through `MAP.md` ("Read when" column); do not read what it does not point you to.
<!-- /charter-trailhead -->
```

In the-grid's `CLAUDE.md` the block goes at the very top, above the existing first heading.

## Alternatives rejected

- **`CLAUDE.md` in `_common`.** Collides with each template's own `CLAUDE.md` (SKIPPED in seed mode). Rejected for the marker-delimited block.
- **Symlink for `map.py`.** `cut-project.sh` copies regular files only (`find -type f`); a symlink would not be seeded. Rejected for mirror + `cmp` test.
- **Stub `MAP.md` in `_common`.** Wrong the moment a file differs. Rejected for generate-after-copy.
- **Guardrails inside `PURPOSE.md`.** Costs tokens every session. Rejected (brief).
- **Hand-written map with a lint.** Drifts. Rejected (brief): generated, `--check` like `catalog.sh`.
- **New compose fragment for the vocabulary.** Needs a `compose.py` change; `AGENTS_base.md` already has the SPECS.md precedent. Rejected (brief).
- **Listing every file in `MAP.md`.** Unbounded token cost; the registry lists only charter files.

## Risks

- **Injected cost on every composed agent (vetoable, Open assumption 8).** About 1.7 KB on each full-profile agent. `openspec/config.yaml` says text that is injected into context must be "opt-in and budgeted". This block is neither opt-in nor per-agent; its budget is the 2000-byte cap, on top of an `AGENTS_base.md` of 2907 bytes.
- **Project pre-commit hook is bypassable** (`--no-verify`); that is accepted (D12), no CI job.
- **Lean agents and `compose.py:741`.** Lean project agents are told signal-file hand-offs do not apply. Knowledge signals are a different mechanism, but the sentence reads as a blanket denial. Fixing it needs a `compose.py` change, which is out of scope here. Left for `knowledge-signals` to decide (UNVERIFIED how many project agents are lean; `deploy.py` treats a missing lock profile as `lean`).
- **Duplicated vocabulary** (AGENTS_base and `signals/README.md`) can drift; the bats assertion covers the six names and the warrant sentence only.
- **Every composed agent grows by about 1.5 KB.** Intended (always-present vocabulary). Regenerating composed output, `dist/personas/` and `plugins/` touches many files; one PR, mechanical. UNVERIFIED whether any test pins composed size; the gate will say.
- **`signals/` collision (Open assumption 3).** An agent following the old handoff text and one following the new filing text write different shapes into one directory. Mitigated by the `→` prefix and the explicit last line of the filing section.
- **`front-door` doc-drift test** (task 2.6b) fails until `docs/architecture.md` lists `signals/` and `knowledge/`. Handled by the unconditional rule in the tasks.md preamble (and the sweep in 6.3): every new tracked script or top-level directory this change adds is listed in `docs/architecture.md` in the same PR that adds it, or, if that file does not exist yet, in the PR description for `front-door` task 2.3.
- **Python on a project machine.** `map.py` needs `python3`; `cut-project.sh` degrades to a printed instruction without it.
- **Trailhead is advisory (L0).** Nothing forces a read. Enforcement is A3.
