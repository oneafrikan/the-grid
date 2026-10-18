## the-grid specifics

- **All 12 wired globally** on every machine via `baseline-submodules.txt`
  (`openspec` whole-repo entry, minus `-openspec/release-openspec`, which is
  upstream's own maintainer release skill).
- **Hard CLI dependency.** Every skill declares `allowed-tools:
  Bash(openspec:*)` and pulls its real instructions from `openspec instructions`
  at runtime — the `SKILL.md` files are shells. Without the binary they
  dead-end immediately:
  ```bash
  npm install -g @fission-ai/openspec@1.12.0    # needs Node >= 20.19.0; matches repos/openspec
  ```
- **Default profile is `core`.** That controls which skills `init` scaffolds
  locally — **not** which CLI commands work. Every command works under `core`.
- **Cut projects get the convention automatically** —
  `project-factory/templates/_common/SPECS.md` lands on every seed *and* every
  retrofit, so spec-driven is the default rather than a per-project decision.
- **Composed agents check for it** — `agent-factory/_core/AGENTS_base.md` adds a
  boot-sequence check for `SPECS.md` / `openspec/`. All 28+ agents across
  `core`, `grid`, `finance-desk` (and any private desk) honour the convention in
  repos that have it, and ignore it in repos that don't.
- **Telemetry is on by default.** Opt out with `OPENSPEC_TELEMETRY=0`.

## Stores (beta, not adopted here)

A **store** is a standalone repo whose only job is planning — same `openspec/`
shape, registered per-machine by name, addressed with `--store <id>`. Solves
planning that spans several repos. the-grid has **not** adopted this; it's
tracked in issue #38 as an open decision. Don't reach for `--store` unless that
issue closes as adopt.

## Gotchas

- A proposal exists to be **rejected cheaply**. If review always rubber-stamps,
  the convention is costing you and buying nothing.
- `update-change` revises the plan and never touches code. `apply-change` is the
  one that writes code. Mixing them up produces a change whose artefacts and
  implementation disagree.
- If implementation proves the spec wrong, update the **delta**, not the code
  silently. Divergence between spec and code is the thing being prevented.
