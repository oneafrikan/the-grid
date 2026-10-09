## Why

Claude Code loads `.claude/rules/**/*.md` natively, and `paths:` frontmatter makes a rule load only when a matching file is touched. the-grid distributes skills and agents but no coding conventions, and the one big rule source it indexes (ECC) bakes in house opinions (mandatory TDD, 80% coverage, "never mutate", auto-spawned agents) and has no packs for SQL/BigQuery, dbt, Bash, Terraform, Django, Flask, Laravel or WordPress. Path-scoped rule packs give every machine and harness the stack conventions for the work at hand at near-zero idle token cost.

## What Changes

- New source format: `rules/<pack>/<topic>.md` (frontmatter = `paths:` only) plus `rules/<pack>/pack.yaml` and `README.md` (sources table).
- New `scripts/rules.py` (Python stdlib): `lint`, `list`, `emit`. Lint enforces path scoping, size caps, a denylist of ECC house opinions, hidden-Unicode rejection, and source attribution.
- `wire.sh` gains a `rules:<pack>` manifest entry (same baseline/overlay grammar, opt-in) that symlinks each rule file into `~/.claude/rules/grid/<pack>/`, with `--check` drift detection and teardown.
- Emitters from the same source: Cursor `.mdc` files, and a managed block in `AGENTS.md` (Codex, OpenCode) or `GEMINI.md` (Gemini CLI), per project.
- 17 packs. Tier 1 written fresh from community style guides: sql (BigQuery-first), dbt, bash, terraform, django, flask, laravel, wordpress. Tier 2 adapted from `repos/ecc/rules/` (MIT, attributed, house opinions stripped): python, typescript (incl. JS), web, react, vue, php, ruby, golang, rust.
- Issue #5 (stack overlays) is superseded for conventions: stacks stay as agent-composition stubs and point at the rule packs that carry the actual conventions.

## Capabilities

### New Capabilities

- `rule-format`: the source format, lint, size/opinion/attribution constraints.
- `rule-wiring`: `rules:<pack>` manifest tier and Claude Code symlink wiring.
- `rule-emitters`: Cursor, AGENTS.md and GEMINI.md emitters.
- `rule-packs`: the 17 packs and their content constraints.

### Modified Capabilities

None. `openspec/specs/` is empty; wiring behaviour of `wire.sh` is specified here as a new capability, not a modification.

## Impact

- Code: new `scripts/rules.py`; edits to `scripts/wire.sh`, `scripts/catalog.sh`, `scripts/sources.sh` (both skip `rules:` lines), `scripts/gate.sh` (one lint check), `tests/helpers/setup.bash` (sandbox `RULES_DIR`), `baseline-submodules.example.txt`, `machines/example.txt`.
- New dirs: `rules/` (packs, `denylist.txt`, `THIRD_PARTY_NOTICES.txt`), `docs/rules.md`.
- Use cases named: data engineering (sql, dbt, bash, python), web/app full-stack (typescript, web, react, vue, django, flask, laravel, php, ruby, golang, rust), WordPress/LAMP (php, wordpress, sql), infrastructure (terraform, bash).
- Token cost: nothing is wired by default. A wired pack costs tokens only when a matching file is read or edited; per-file cap 4 KB, per-pack cap 9 KB.
- Workstream 11 (`multi-harness`) reuses `rules.py emit` instead of building its own rule emitters. Workstream 3 (`manifest-lock-install`) must carry `rules:` entries into `grid.yaml`.
- Issue #5 is closed as superseded when this lands.

## Non-goals

- No always-on "common" layer. ECC's `rules/common` is 18 KB loaded every session; we ship none.
- No per-file wiring (`rules:<pack>/<topic>`); the unit is the pack.
- No Swift, Dart, Java, Kotlin, C#, C++, Angular, Nuxt, React Native packs. Add later by the same format.
- No MySQL/Postgres-specific packs; `sql` is warehouse-first with portable safety rules only.
- No editing of `compose.py` or fragments in `agent-factory/stacks/`; no rule injection into composed agents.
- No project-level Claude emitter (copying rules into a repo's `.claude/rules/` for teammates).
- No home-directory targets for Codex/Gemini/OpenCode (`~/.codex/AGENTS.md` etc.); workstream 11 owns those locations.
- No Claude Code hook advice in packs (ECC's `hooks.md` files); workstream 6 owns hooks.
- No design-taste rules (ECC `web/design-quality.md` anti-template policy).
- No rules copied verbatim from ECC's `common/` or any mandatory-workflow content.
- No network calls in the gate; URL liveness check is an opt-in flag.
