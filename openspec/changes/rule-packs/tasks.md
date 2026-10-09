# Tasks

Conventions for every group: work on a branch off `next`, open one PR to `next`, do not touch `main`. Verify command is `bash scripts/gate.sh` unless stated. Tests never touch the real `~/.claude`. Decisions are in `design.md` (`Decided:` lines); do not re-decide them.

Content groups 6-12 (packs) additionally: the issue for each group carries the label `ws:rule-packs`, which gives the loop worker `MAX_BUDGET_USD=15` (instead of the default 5); the worker runs only under the loop's isolated worker (loops, operator decision Q1), where `WebFetch` is allowed; the two reviewers are Agent-tool subagents with `model: opus` run inside that worker session, so its cap bounds them. If `WebFetch` is unavailable or denied at any step (author fetch or Reviewer A), stop and open the PR as a draft labelled `needs-human`.

## 1. Rule format, lint, and pack scaffold

Depends on: vetting#1 (`scripts/audit.py` scans hidden Unicode in `rules/`; this lint does not). vetting#5 (the gate's `audit` check) is merge order only, not a build dependency.

- [ ] 1.1 Create `scripts/rules.py` (Python 3 stdlib only, 3.8-compatible, commented) with subcommands `lint` and `list` per `design.md`: strict frontmatter parser (only `paths:`), flat `pack.yaml` reader, all `E_*` checks in the lint table (including `E_STYLE` and the extended `E_PATHS`), `--root DIR` (default: repo root, honour `GRID_DIR`), `--check-urls` (HEAD each Sources URL, never run by tests). `list` prints `pack  tier  files  bytes  summary` sorted in C locale.
- [ ] 1.2 Create `rules/denylist.txt` (contents from `design.md`), `rules/THIRD_PARTY_NOTICES.txt` (full ECC MIT licence text copied from `repos/ecc/LICENSE`, then a section `Adapted packs` listing pack names, initially empty with a comment), `rules/review-a.prompt.txt` and `rules/review-b.prompt.txt` (text exactly as in `design.md` "Review process"), and `rules/README.md` (this file is not wired; contents: the "Pack authoring template" section of `design.md` copied verbatim, the file format, `pack.yaml`, the README Sources table, the review procedure pointing at the two prompt files, size caps).
- [ ] 1.3 Add a `run_rules_check` function and `check rules      run_rules_check` to `scripts/gate.sh` (place the `check` line directly before `check bats       run_bats`, with a comment). The function skips loudly, matching `run_compose_check`: if `python3` is not on PATH or `scripts/rules.py` does not exist, print `    python3 or scripts/rules.py absent — skipped`, append `rules` to `SKIPPED`, return 0; otherwise run `python3 scripts/rules.py lint`. Lint on an empty `rules/` (no packs) must pass.
- [ ] 1.3a Add two cases to `tests/test_gate.bats` using its existing fake-grid setup: (a) no `scripts/rules.py` in the fake grid -> gate exits 0 and its last line lists `rules` in `skipped:`; (b) a placeholder `scripts/rules.py` present in the fake grid, run through the existing `run_gate` (its `stubbin` PATH has no `python3`) -> same assertion. Neither case adds `python3` to `stubbin`.
- [ ] 1.4 Create `tests/test_rules.bats`. Build fixture packs in a temp dir inside each test (do not commit fixtures). Cases: valid pack passes; each `E_*` code has one failing fixture (missing paths, banned glob `**/*`, banned glob `**/*.*`, nested braces, empty brace alternative, extra frontmatter key, prose paragraph line, block-quote line, 241-character bullet, 11-line fenced block, hedged bullet `- You should ...`, `extends [common/x.md]` line, no title, 4097-byte file, pack over 9216, denylist hit, bad tier/adapted_from mismatch, README missing a file row, tier 2 missing attribution line, uppercase file name); `list` output sorted and stable across two runs; and one test `real packs lint clean` running `python3 scripts/rules.py lint` on the real `rules/`.
- [ ] 1.5 Verify: `tests/lib/bats-core/bin/bats tests/test_rules.bats tests/test_gate.bats` then `bash scripts/gate.sh`; `shellcheck` is not needed (no new shell). Second run of lint changes nothing (it writes nothing).

Acceptance: `python3 scripts/rules.py lint` exits 0 on the real tree and non-zero with the expected code for each fixture.

## 2. Claude Code wiring: `rules:<pack>` manifest tier

Depends on: 1, foundations#2 (`GRID_BASELINE`), foundations#8 (the `GRID_DRY_HOME` task added under G1; if foundations placed it in a new group 9, read #9), manifest-lock-install#3 (rebase onto its `wire.sh` edits), hook-profiles#4 (its `load_manifest` `hook:` cases and the `CLAUDE_CONFIG_DIR` export in `tests/helpers/setup.bash`; rebase onto both).

- [ ] 2.1 Edit `scripts/wire.sh`: add `RULES_DIR` (default `$HOME/.claude/rules`) to the header docs, and derive its default from the same home base the foundations `GRID_DRY_HOME` logic uses (when `GRID_DRY_HOME` is set and `RULES_DIR` is unset, `RULES_DIR` = `$GRID_DRY_HOME/.claude/rules`), so no dry run can reach the real `~/.claude/rules`; parse `rules:<name>` and `-rules:<name>` in `load_manifest` (cases placed directly after the `project:*`/`-project:*` cases, before the generic `-*/*`, `-*`, `*/*`, `*` cases, so they are not mistaken for repos); keep `WIRED_RULES`/`DENY_RULES` arrays; add a recursive teardown of grid-owned symlinks under `$RULES_DIR/grid` followed by deletion of empty dirs there; add a wire step per design (`rules/<pack>/*.md` except `README.md`, `ln -sfn`, skip real files, warn and skip unknown packs); add `rule` rows to `MANIFEST_ROWS`; extend `--check` with a `rules` kind: pass `RULES_DIR="$tmp/rules"` to the throwaway run, and add a separate recursive lister (`find "$1/grid" -type l`, printing `relpath -> target` for targets under `GRID_DIR`, same real-file shadow filter) because the existing `links()` is `-maxdepth 1`.
- [ ] 2.2 Edit `scripts/catalog.sh` and `scripts/sources.sh`: directly after the existing `project:*|-project:*) continue ;;` line in each, add the generic typed-entry skip `*:*|-*:*) continue ;;` with a comment (`# typed entries (rules:, harness:, hook:, ...) are not repos`), so output is unchanged by `rules:` and every other typed line. Do not add a `rules:`-specific case. If a `hook:*` case already exists from hook-profiles, leave it.
- [ ] 2.3 Edit `tests/helpers/setup.bash`: in `common_setup` create `MOCK_RULES=$(mktemp -d)` and `export RULES_DIR="$MOCK_RULES"` before `assert_sandboxed`; add `"${RULES_DIR:-}"` to the `assert_sandboxed` loop; add `$MOCK_RULES` to the `rm -rf` and `RULES_DIR` to the `unset` in `common_teardown`.
- [ ] 2.4 Edit `baseline-submodules.example.txt` and `machines/example.txt`: add a commented `rules:` section documenting the grammar and a few commented example entries (`# rules:sql`, `# -rules:wordpress`); nothing active.
- [ ] 2.5 Add tests to `tests/test_wiring.bats` (or a new `tests/test_rules_wiring.bats` if cleaner): with no `rules:` entry nothing is created under `RULES_DIR`; `rules:foo` creates `$RULES_DIR/grid/foo/<topic>.md` symlinks resolving to the source and no `README.md`; second run is a no-op (same link set, exit 0); removing the entry then re-running removes the links and the empty dir; `-rules:foo` in an overlay subtracts; unknown pack warns on stderr, exits 0, adds a `skipped` manifest row; a real file at a target path is left untouched; `wire.sh --check` exits 0 after wiring and 1 after a link is deleted; foreign symlinks in `$RULES_DIR/grid` are not removed; `catalog.sh --check` unaffected by a `rules:` line; `catalog.sh` and `sources.sh` output unchanged by each of `rules:sql`, `-rules:sql`, `harness:codex` and `-hook:auto-handoff` lines added to a fixture baseline; GRID_DRY_HOME sentinel: unset `RULES_DIR`, set `HOME` to a fake real-home containing `.claude/rules/sentinel.md` (record its checksum), run `wire.sh` with `GRID_DRY_HOME=$(mktemp -d)` and a `rules:foo` entry, then assert the sentinel's checksum is unchanged, nothing new exists under the fake real-home's `.claude/rules`, and the links landed under `$GRID_DRY_HOME/.claude/rules/grid/foo`.
- [ ] 2.6 Verify: `tests/lib/bats-core/bin/bats tests/` then `bash scripts/gate.sh`. Do not run `wire.sh` against the real home.

Acceptance: the new bats cases pass and the whole suite stays green.

## 3. Emit CLI and Cursor `.mdc` output

Depends on: 1.

- [ ] 3.1 Extend `scripts/rules.py` with the full `emit` argument surface from `design.md` (`--harness cursor|agents-md|gemini`, `--packs`, `--out`, `--check`, `--root`; exit codes 0/1/2; `wrote`/`removed` stdout lines). `agents-md` and `gemini` may exit 2 with `not implemented` until group 4. Implement `--harness cursor`: output `<out>/grid-<pack>-<topic>.mdc` (default `--out .cursor/rules`, relative to the current directory), `description` from the H1, brace-expanded `globs` JSON-style list, `alwaysApply: false`, marker comment line, deterministic output, stale marker-carrying `grid-*.mdc` removed, unmarked files never touched, unknown pack exit 2, `--check` writes nothing and exits 1 on any difference.
- [ ] 3.2 Add tests to `tests/test_rules.bats` (always pass a temp `--out` or `cd` into a temp dir): default `--out` lands in `./.cursor/rules`; explicit `--out DIR` lands there; unknown `--harness` and unknown pack exit 2 and write nothing; exact expected `.mdc` text for a fixture rule (frontmatter and body); brace expansion (`**/*.{ts,tsx}` -> two globs; `**/*.{test,spec}.{tsx,jsx}` -> four globs in source order); second emit is byte-identical and `--check` exits 0; dropping a pack from `--packs` deletes only its marked files; a hand-written `grid-keep.mdc` without the marker survives; `--check` exits 1 when a file is edited.
- [ ] 3.3 Verify: `tests/lib/bats-core/bin/bats tests/test_rules.bats` then `bash scripts/gate.sh`.

Acceptance: Cursor emit is idempotent and never modifies files it did not generate.

## 4. AGENTS.md and GEMINI.md block output

Depends on: 3 (shares the `emit` plumbing).

- [ ] 4.1 Implement `emit --harness agents-md` (default `--out AGENTS.md`) and `--harness gemini` (default `--out GEMINI.md`) per design, with the fixed `BLOCK_CAP = 12288`: one managed block between the BEGIN/END markers, H1 removed and the section header `### <pack> / <topic> (applies to: ...)`, file created if missing, content outside the markers preserved byte-for-byte, exit 2 without writing if marker pairs are unbalanced or the block exceeds the cap, empty selection removes the block (and deletes the file only if nothing else remains).
- [ ] 4.2 Add tests to `tests/test_rules.bats` (temp dirs only): creating the block in a new file; `--out` pointing into a not-yet-existing nested dir creates parents; replacing the block in a file with surrounding user text (surrounding bytes unchanged); second run byte-identical; `--check` semantics; over-cap (two fixture packs totalling more than 12288 bytes of block) exits 2 and leaves the file unchanged; unbalanced markers exit 2; empty `--packs ""` removes the block and, for a block-only file, deletes the file; `agents-md` and `gemini` produce byte-identical blocks.
- [ ] 4.3 Verify: `tests/lib/bats-core/bin/bats tests/test_rules.bats` then `bash scripts/gate.sh`.

Acceptance: block emit is idempotent, bounded, and never alters text outside its markers.

## 5. Docs, issue #5 relation, and repo context

Depends on: 2, 4.

- [ ] 5.1 Create `docs/rules.md`: what rule packs are, the four outputs, the `emit` interface table (copied from `design.md`, stated as the contract `multi-harness` calls), the `rules:<pack>` grammar with examples, opt-in/token-cost model with the worst-case co-load note, how to author or adapt a pack (link `rules/README.md`), `python3 scripts/rules.py list` for the pack inventory (no embedded pack table), the stack-stub to pack mapping table from `design.md`, the Tier 2 attribution policy, and the line "Effect of packs on model behaviour: unmeasured (see task 13.5 of the rule-packs change)". No personal data, no absolute home paths.
- [ ] 5.2 Edit `agent-factory/stacks/{lamp,wordpress,data-engineering,modern-frontend,astro}/stack.yaml`: add one comment line each, `# Conventions for this stack live in rule packs: <list> (see docs/rules.md).` Do not change any key. Verify `agent-factory/.venv/bin/python agent-factory/compose.py agent-factory/examples/core.yaml --target claude-code --check` still passes if the venv exists.
- [ ] 5.3 Edit `CLAUDE.md`: add `rules/`, `scripts/rules.py`, the `rules:` manifest grammar and `RULES_DIR` to Key files and the wire.sh contract (keep it short). Edit `README.md` only with a one-line pointer to `docs/rules.md` where skills wiring is described.
- [ ] 5.4 Edit `TODO.md`: in the `agent-factory — everything else` table, change the `#5` row's Labels cell to `superseded by rule packs (docs/rules.md)`; touch nothing else.
- [ ] 5.5 Verify: `bash scripts/gate.sh`. Report in the PR body that issue #5 can be closed as superseded (do not close it).

Acceptance: docs match the implemented flags (copy commands from `rules.py --help`), gate green.

## 6. Packs: sql and dbt (tier 1, data engineering)

Depends on: 1.

- [ ] 6.1 Author `rules/sql/{pack.yaml,README.md,style.md,bigquery.md,safety.md}` and `rules/dbt/{pack.yaml,README.md,models.md,schema-tests.md,project.md}` per the `design.md` inventory and sources. Rule files: imperative bullets, title line, paths scoped as designed, each at most about 2.5 KB. sql is BigQuery/GoogleSQL-first (partition filters, no `SELECT *`, cost/dry-run, CTE style, naming, joins) with portable safety (parameterised queries, no string-built SQL, destructive DML guards); dbt covers layers (staging/intermediate/marts), `ref`/`source` only, materialisation choice, incremental pitfalls, tests and docs on keys, project config.
- [ ] 6.2 Fetch every cited URL and confirm it loads (WebFetch); record the exact URL per rule file in each README Sources table. Fix or drop any bullet you cannot trace to a source. If WebFetch is unavailable in the session, stop and open a draft PR labelled `needs-human`. Follow the authoring template in `rules/README.md` (imperative, one construct per bullet, nothing the model does unprompted).
- [ ] 6.3 Run the two-reviewer check exactly as in `design.md` "Review process" (prompt files `rules/review-a.prompt.txt` and `rules/review-b.prompt.txt`, fresh Opus subagents, at most 2 re-runs each); paste both outputs in the PR body; both must end `VERDICT: PASS`, else leave the PR as a draft labelled `needs-human`.
- [ ] 6.4 Verify: `python3 scripts/rules.py lint` and `bash scripts/gate.sh`.

Acceptance: lint clean; every rule file has a sourced README row; reviewer outputs attached.

## 7. Packs: bash and terraform (tier 1, scripts and infrastructure)

Depends on: 1.

- [ ] 7.1 Author `rules/bash/{pack.yaml,README.md,style.md,safety.md,portability.md}` and `rules/terraform/{pack.yaml,README.md,style.md,modules.md,safety.md}`. bash: Google Shell Style Guide plus ShellCheck/BashPitfalls (quoting, `set -euo pipefail` with its caveats, `[[ ]]`, arrays, traps and temp files, idempotent re-runnable scripts, shellcheck clean) and portability (macOS ships bash 3.2 and BSD userland: avoid `mapfile`, `declare -A`, `readlink -f`, `sed -i` without suffix, GNU-only flags; prefer POSIX utilities or feature checks); the bash README states that extensionless shebang scripts are not matched by the path globs. terraform: HashiCorp style (fmt, naming, file layout, variables/outputs with types and descriptions), modules (small, versioned, no provider config inside), safety (remote state, no secrets in code or state-adjacent files, `plan` before `apply`, lifecycle `prevent_destroy` for stateful resources, pinned provider versions and the lock file).
- [ ] 7.2 Fetch every cited URL; fill each README Sources table; drop untraceable bullets.
- [ ] 7.3 Run the two-reviewer check exactly as in `design.md` "Review process"; paste both outputs in the PR body; both must end `VERDICT: PASS`, else leave the PR as a draft labelled `needs-human`.
- [ ] 7.4 Verify: `python3 scripts/rules.py lint` and `bash scripts/gate.sh`.

Acceptance: lint clean; sources table complete; reviewer outputs attached.

## 8. Packs: django and flask (tier 1, Python web)

Depends on: 1.

- [ ] 8.1 Author `rules/django/{pack.yaml,README.md,structure.md,orm.md,security.md}` and `rules/flask/{pack.yaml,README.md,structure.md,security.md}`. django: app layout and settings split, thin views, ORM (select_related/prefetch_related, avoid N+1, `F()`/`Q()`, transactions, `update_fields`), migrations (never edit applied migrations, data vs schema migrations, reversible), security from Django's deployment checklist (`DEBUG`, `SECRET_KEY`, `ALLOWED_HOSTS`, CSRF, `mark_safe`, raw SQL parameters). flask: application factory, blueprints, config from environment, extensions initialised in the factory, security (secret key, `SESSION_COOKIE_*`, Jinja autoescape, no `debug=True` outside dev, parameterised SQL, CSRF via the chosen extension). Note in the flask README that its path scope is heuristic.
- [ ] 8.2 Fetch every cited URL; fill each README Sources table; drop untraceable bullets.
- [ ] 8.3 Run the two-reviewer check exactly as in `design.md` "Review process"; paste both outputs in the PR body; both must end `VERDICT: PASS`, else leave the PR as a draft labelled `needs-human`.
- [ ] 8.4 Verify: `python3 scripts/rules.py lint` and `bash scripts/gate.sh`.

Acceptance: lint clean; sources table complete; reviewer outputs attached.

## 9. Packs: php, laravel, wordpress (PHP family)

Depends on: 1.

- [ ] 9.1 Author `rules/php/{pack.yaml,README.md,style.md,patterns.md,security.md,testing.md}` as tier 2 adapted from `repos/ecc/rules/php/` (drop `hooks.md`, the Immutability section, coverage language, "See skill" lines); set `adapted_from`, the README attribution line, and add `php` to `rules/THIRD_PARTY_NOTICES.txt` `Adapted packs`. Author tier 1 `rules/laravel/{pack.yaml,README.md,structure.md,eloquent.md,security.md}` (thin controllers, Form Requests, policies, Eloquent eager loading and mass-assignment, migrations, queues, config/env, Pint) and `rules/wordpress/{pack.yaml,README.md,standards.md,security.md,structure.md}` (WordPress PHP coding standards, validate/sanitise/escape/nonce/capability checks, `$wpdb->prepare`, hooks and enqueue, text domains and i18n, no direct file/DB access shortcuts, prefixing). Use the wordpress path scope from the `design.md` inventory and state in its README the remaining gap (plugin or theme files that match none of the globs).
- [ ] 9.2 Fetch every cited URL; fill each README Sources table; drop untraceable bullets.
- [ ] 9.3 Run the two-reviewer check exactly as in `design.md` "Review process"; paste both outputs in the PR body; both must end `VERDICT: PASS`, else leave the PR as a draft labelled `needs-human`.
- [ ] 9.4 Verify: `python3 scripts/rules.py lint` and `bash scripts/gate.sh`.

Acceptance: lint clean (including `E_ATTRIBUTION` for php); sources complete; reviewer outputs attached.

## 10. Packs: python and typescript (tier 2)

Depends on: 1.

- [ ] 10.1 Author `rules/python/{pack.yaml,README.md,style.md,security.md,testing.md,fastapi.md}` from `repos/ecc/rules/python/` (merge coding-style and patterns into `style.md`; drop `hooks.md`; replace the Immutability section with the language-native guidance of PEP 8/PEP 484 only; testing = pytest conventions with no coverage target) and `rules/typescript/{pack.yaml,README.md,style.md,patterns.md,testing.md}` from `repos/ecc/rules/typescript/` (JS included: tsconfig `strict`, `unknown` over `any`, boundary validation, error handling, async, no `React.FC` moves to react). Trim to the 4 KB / 9 KB caps; update `THIRD_PARTY_NOTICES.txt`.
- [ ] 10.2 Fetch every cited URL; fill each README Sources table (include which ECC file each rule file was adapted from in "Adaptation notes"); drop untraceable bullets.
- [ ] 10.3 Run the two-reviewer check exactly as in `design.md` "Review process"; paste both outputs in the PR body; both must end `VERDICT: PASS`, else leave the PR as a draft labelled `needs-human`.
- [ ] 10.4 Verify: `python3 scripts/rules.py lint` and `bash scripts/gate.sh`.

Acceptance: lint clean; no denylist hits; reviewer outputs attached.

## 11. Packs: web, react, vue (tier 2, frontend)

Depends on: 1.

- [ ] 11.1 Author `rules/web/{pack.yaml,README.md,style.md,performance.md,security.md}` (semantic HTML, accessibility basics from WCAG 2.2, CSS custom properties, animation properties, Core Web Vitals targets from web.dev, CSP/SRI/security headers; drop `design-quality.md` and `hooks.md`), `rules/react/{pack.yaml,README.md,hooks.md,patterns.md,security.md,testing.md}` (condense ECC's 31 KB to at most 9 KB: Rules of Hooks, effects only for syncing with external systems, state placement, RSC boundary, `dangerouslySetInnerHTML`, Testing Library queries by role; no coverage numbers) and `rules/vue/{pack.yaml,README.md,style.md,patterns.md,security.md,testing.md}` (Composition API with `<script setup>`, official style guide essentials, XSS via `v-html`, test conventions). Update `THIRD_PARTY_NOTICES.txt`.
- [ ] 11.2 Fetch every cited URL; fill each README Sources table; record dropped ECC material in "Adaptation notes".
- [ ] 11.3 Run the two-reviewer check exactly as in `design.md` "Review process"; paste both outputs in the PR body; both must end `VERDICT: PASS`, else leave the PR as a draft labelled `needs-human`.
- [ ] 11.4 Verify: `python3 scripts/rules.py lint` and `bash scripts/gate.sh`; report `python3 scripts/rules.py list` output in the PR body so the `.tsx` co-load total (typescript + web + react) is visible.

Acceptance: lint clean; react at most 9216 bytes total; reviewer outputs attached.

## 12. Packs: ruby, golang, rust (tier 2)

Depends on: 1.

- [ ] 12.1 Author `rules/ruby/{pack.yaml,README.md,style.md,patterns.md,security.md,testing.md}` (Ruby style guide, Rails conventions, Rails security guide, RSpec/Minitest conventions), `rules/golang/{pack.yaml,README.md,style.md,patterns.md,security.md,testing.md}` (ECC's Go files are tiny; write from Effective Go, Code Review Comments and the Google Go Style Guide: gofmt, error wrapping, context, interfaces, goroutine lifetimes, table-driven tests, `go vet`/`govulncheck`) and `rules/rust/{pack.yaml,README.md,style.md,patterns.md,security.md,testing.md}` (trim ECC's 16 KB to at most 9 KB: API Guidelines naming, error handling with `Result`, ownership/borrowing guidance, `unsafe` hygiene, `cargo clippy`/`cargo audit`, test layout). Drop all `hooks.md`. Update `THIRD_PARTY_NOTICES.txt`.
- [ ] 12.2 Fetch every cited URL; fill each README Sources table; record dropped ECC material.
- [ ] 12.3 Run the two-reviewer check exactly as in `design.md` "Review process"; paste both outputs in the PR body; both must end `VERDICT: PASS`, else leave the PR as a draft labelled `needs-human`.
- [ ] 12.4 Verify: `python3 scripts/rules.py lint` and `bash scripts/gate.sh`.

Acceptance: lint clean; rust at most 9216 bytes; reviewer outputs attached.

## 13. HUMAN: smoke-test in real harnesses and choose wired packs

Depends on: 2, 3, 4, and at least groups 6 and 7 merged.

- [ ] 13.1 HUMAN: on one machine, add `rules:sql` and `rules:bash` to your untracked `baseline-submodules.txt` (or `machines/<host>.txt`), run `bash scripts/wire.sh`, open Claude Code in a repo with a `.sql` file and a `.sh` file, and confirm via `/memory` or a rules listing that `grid/sql/*` loads only after touching the `.sql` file.
- [ ] 13.2 HUMAN: in a scratch repo run `python3 <grid>/scripts/rules.py emit --harness cursor --packs sql,bash` and confirm Cursor lists the `.mdc` rules with the right globs (confirms list-form `globs`). Run `--harness gemini` and confirm the installed Gemini CLI loads root `GEMINI.md` (if it expects `.gemini/GEMINI.md`, file a one-line fix to the emitter path). Confirm Codex reads the `AGENTS.md` block.
- [ ] 13.3 HUMAN: choose which packs go in each machine's untracked baseline/overlay (suggested start: the packs for languages actually used on that machine). No tracked file changes are required.
- [ ] 13.4 HUMAN: close issue #5 as superseded (reference this change).
- [ ] 13.5 HUMAN: behavioural spot check, one pack. In a scratch repo, ask the same prompt twice in fresh sessions, once with `rules:sql` wired and once without, e.g. "write a query returning all columns for last month's orders from a date-partitioned BigQuery table". Note whether the wired run uses named columns and a partition filter and the unwired run does not. Record the result (or "no visible difference") in `docs/rules.md`, replacing the "Effect of packs on model behaviour: unmeasured" line.

Acceptance: items 13.1-13.2 pass or produce a concrete bug report against groups 2-4; 13.5 outcome is recorded either way.
