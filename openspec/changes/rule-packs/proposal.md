## Why

Claude Code loads `.claude/rules/**/*.md` natively, and `paths:` frontmatter makes a rule load only when a matching file is touched. the-grid distributes skills and agents but no coding conventions, and the one big rule source it indexes (ECC) bakes in house opinions (mandatory TDD, 80% coverage, "never mutate", auto-spawned agents) and has no packs for SQL/BigQuery, dbt, Bash, Terraform, Django, Flask, Laravel or WordPress. Path-scoped rule packs give every machine and harness the stack conventions for the work at hand at near-zero idle token cost.

## What Changes

- New source format: `rules/<pack>/<topic>.md` (frontmatter = `paths:` only) plus `rules/<pack>/pack.yaml` and `README.md` (sources table).
- New `scripts/rules.py` (Python stdlib): `lint`, `list`, `emit`. Lint enforces path scoping, size caps, a denylist of ECC house opinions, and source attribution (hidden-Unicode scanning is `vetting`'s `audit.sh --owned`, which already covers `rules/`).
- `wire.sh` gains a `rules:<pack>` manifest entry (same baseline/overlay grammar, opt-in) that symlinks each rule file into `~/.claude/rules/grid/<pack>/`, with `--check` drift detection and teardown.
- Emitters from the same source: `rules.py emit --harness cursor|agents-md|gemini --packs … [--out PATH] [--check]` writes Cursor `.mdc` files, or a managed block in `AGENTS.md` (Codex, OpenCode) or `GEMINI.md` (Gemini CLI). This is the single rule-emitter interface; `multi-harness` calls it with its own `--out` paths.
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

- Code: new `scripts/rules.py`; edits to `scripts/wire.sh`, `scripts/catalog.sh`, `scripts/sources.sh` (both gain the generic typed-entry skip `*:*|-*:*`, owned here as the first change in merge order to touch them), `scripts/gate.sh` (one lint check, skipped loudly without `python3`), `tests/test_gate.bats` (skip cases), `tests/helpers/setup.bash` (sandbox `RULES_DIR`), `baseline-submodules.example.txt`, `machines/example.txt`.
- New dirs: `rules/` (packs, `denylist.txt`, `THIRD_PARTY_NOTICES.txt`), `docs/rules.md`.
- Use cases named: data engineering (sql, dbt, bash, python), web/app full-stack (typescript, web, react, vue, django, flask, laravel, php, ruby, golang, rust), WordPress/LAMP (php, wordpress, sql), infrastructure (terraform, bash).
- Token cost: nothing is wired by default. A wired pack costs tokens only when a matching file is read or edited; per-file cap 4 KB, per-pack cap 9 KB.
- `multi-harness` calls `rules.py emit` (interface in `design.md`) instead of building its own rule emitters or a `dist/rules/` tree.
- Builds on `foundations` (`GRID_BASELINE`, `GRID_DRY_HOME`), `vetting` (hidden-Unicode scan of `rules/`), `manifest-lock-install` and `hook-profiles` (earlier `wire.sh` and test-helper edits); merges after `hook-profiles` per the shared merge order.
- Content PRs (groups 6-12) run in the overnight loop and need its isolated worker (WebFetch allowed) and a raised per-issue budget for issues labelled `ws:rule-packs`.
- Issue #5 is closed as superseded when this lands.

## Non-goals

- No always-on "common" layer. ECC's `rules/common` is 18 KB loaded every session; we ship none.
- No per-file wiring (`rules:<pack>/<topic>`); the unit is the pack.
- No Swift, Dart, Java, Kotlin, C#, C++, Angular, Nuxt, React Native packs. Add later by the same format.
- No MySQL/Postgres-specific packs; `sql` is warehouse-first with portable safety rules only.
- No editing of `compose.py` or fragments in `agent-factory/stacks/`; no rule injection into composed agents.
- No project-level Claude emitter (copying rules into a repo's `.claude/rules/` for teammates).
- No knowledge of home-directory harness locations (`~/.codex/AGENTS.md` etc.); `emit` writes wherever `--out` says and `multi-harness` chooses those paths.
- No `rules:` support in `grid.yaml`/`grid install`; rules are wired from the manifest files only.
- No Claude Code hook advice in packs (ECC's `hooks.md` files); `hook-profiles` owns hooks.
- No design-taste rules (ECC `web/design-quality.md` anti-template policy).
- No rules copied verbatim from ECC's `common/` or any mandatory-workflow content.
- No network calls in the gate; URL liveness check is an opt-in flag.
