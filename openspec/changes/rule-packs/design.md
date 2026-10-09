## Context

- Claude Code loads `.claude/rules/**/*.md` (project) and `~/.claude/rules/**/*.md` (user), recursively. Frontmatter `paths:` (glob list, brace expansion allowed) makes a rule load only when Claude reads or edits a matching file. No `paths:` means always loaded. ECC ships exactly this shape.
- Every `*.md` under the rules dir is a rule. A `README.md` placed there would load on every session, so pack READMEs must never be wired.
- Cursor reads `.cursor/rules/*.mdc` with frontmatter `description`, `globs`, `alwaysApply` (shape seen in `repos/ecc/.cursor/rules/*` and the `.md`->`.mdc` rename in `repos/ecc/scripts/lib/install-targets/cursor-project.js`). Codex and OpenCode read `AGENTS.md`. Gemini CLI reads `GEMINI.md` (ECC's gemini target writes `.gemini/GEMINI.md`). None of these has path scoping, so a block in `AGENTS.md`/`GEMINI.md` is always-on and must be capped.
- Existing wiring: `scripts/wire.sh` reads `baseline-submodules.txt` + `machines/<host>.txt` (+ `.local.txt`) with entry grammar `repo`, `repo/skill`, `project:<name>`, and `-` subtractions; it tears down grid-owned symlinks and rebuilds them each run; `--check` wires into temp dirs and diffs. `catalog.sh` and `sources.sh` re-parse the baseline and skip `project:` lines.
- ECC rules (`repos/ecc/rules/`, MIT, checkout `ef648e0`) total 105 KB for the packs in scope, many files 4-7 KB, plus per-pack `hooks.md` that is advice about Claude Code hooks. `common/` (18 KB, always on) carries the house opinions.
- Issue #5: `agent-factory/stacks/*/stack.yaml` are stubs (`fragments: []`) whose planned job is to append stack text to a composed agent's `AGENTS.md`. That text would be always-on inside that agent and Claude-only.

## Approach

```
rules/
  denylist.txt                 # regexes of ECC house opinions (lint input)
  THIRD_PARTY_NOTICES.txt      # MIT notice for ECC + list of adapted pack files
  README.md                    # how to author a pack (not wired)
  <pack>/
    pack.yaml                  # flat key: value metadata
    README.md                  # purpose + Sources table (not wired)
    <topic>.md                 # rule files; frontmatter = paths only
scripts/rules.py               # lint | list | emit   (Python 3 stdlib only)
```

- One source, three outputs:
  - Claude Code: wire.sh symlinks each `<topic>.md` as-is into `$RULES_DIR/grid/<pack>/<topic>.md` (no compile; the source file is already a valid Claude rule).
  - Cursor: `rules.py emit --target cursor` writes `.cursor/rules/grid-<pack>-<topic>.mdc`.
  - Codex/OpenCode/Gemini: `rules.py emit --target agents-md|gemini-md` writes one managed block.
- Claude wiring is tiered by the manifest (opt-in); emitters are per project and take an explicit `--packs` list.
- Content is plain imperative bullets sourced from community style guides. The lint is what keeps ECC's opinions out and keeps files small.

### Rule file format

```markdown
---
paths:
  - "**/*.sql"
---
# BigQuery

- Select only the columns you need; never `SELECT *` on a wide or partitioned table.
- Filter on the partition column in every query against a partitioned table.
```

Grammar (parsed by a hand-written strict parser in `rules.py`; no PyYAML so it runs on any machine without the agent-factory venv):

- Frontmatter is the first block delimited by lines `---`. It contains exactly one key, `paths:`, followed by one or more lines of the form `  - "<glob>"` (two-space indent, double quotes). Any other key or shape is `E_FRONTMATTER`.
- A glob must not start with `/`, contain `..`, or be one of `*`, `**`, `**/*` (these make a rule effectively always-on): `E_PATHS`.
- After the frontmatter: a first line `# <Title>` (the title becomes the Cursor `description`), then bullets and short sections. No prose paragraphs longer than 2 lines.
- Brace expansion `{a,b}` is allowed in globs. Claude consumes it natively; the Cursor emitter expands it into separate globs.

### pack.yaml

```yaml
# Flat "key: value" lines only. Parsed by rules.py (no YAML library).
summary: Warehouse-first SQL (BigQuery), portable safety rules
tier: 1                      # 1 = written fresh, 2 = adapted from ECC
adapted_from: affaan-m/ECC rules/python @ ef648e0 (MIT)   # required iff tier 2
```

### Pack README.md (required, never wired)

```markdown
# sql

Warehouse-first SQL conventions. Not tuned for MySQL/Postgres OLTP.

## Sources

| Rule file | Source |
|---|---|
| style.md | https://docs.getdbt.com/best-practices/how-we-style/2-how-we-style-our-sql |
| bigquery.md | https://cloud.google.com/bigquery/docs/best-practices-performance-overview |
| safety.md | https://cloud.google.com/bigquery/docs/parameterized-queries |

## Adaptation notes
(tier 2 only) What was dropped from ECC and why; "Adapted from affaan-m/ECC (MIT), see rules/THIRD_PARTY_NOTICES.txt".
```

Lint requires: every `<topic>.md` basename appears in the table with at least one `https://` URL on its row (`E_SOURCES`). Tier 2 packs must contain the literal line `Adapted from affaan-m/ECC (MIT)` (`E_ATTRIBUTION`).

### Lint checks (`python3 scripts/rules.py lint [--root DIR] [--check-urls]`)

Stable codes, one line per finding `E_CODE path: message`, exit 1 if any:

| Code | Check |
|---|---|
| `E_FRONTMATTER` | missing/extra/malformed frontmatter |
| `E_PATHS` | empty `paths:` or a banned glob |
| `E_TITLE` | no `# Title` first line after frontmatter |
| `E_FILE_SIZE` | rule file over 4096 bytes |
| `E_PACK_SIZE` | sum of a pack's rule files over 9216 bytes |
| `E_OPINION` | any regex in `rules/denylist.txt` matches (case-insensitive) |
| `E_UNICODE` | zero-width, bidi-control or BOM characters in any pack file |
| `E_PACK_META` | missing `pack.yaml`, missing `summary`, bad `tier`, tier/`adapted_from` mismatch |
| `E_SOURCES` | README missing, or a rule file with no https URL row |
| `E_ATTRIBUTION` | tier 2 pack lacks the attribution line, or its pack name is absent from `THIRD_PARTY_NOTICES.txt` |
| `E_NAME` | pack or file name not kebab-case lowercase; a `.md` other than `README.md` that is not a rule |

`--check-urls` (off by default, never in the gate) HEADs every Sources URL and reports `E_URL` for non-2xx/3xx, same spirit as `sources.sh --check`.

`denylist.txt` (one case-insensitive extended regex per line, `#` comments), initial contents:

```
\balways create new\b
^#+ *immutab
\(CRITICAL\)
\b[0-9]{2} ?% ?(test )?coverage\b
\bcoverage (target|threshold|minimum|requirement)s?\b
\bTDD\b|\btest-driven\b
includeCoAuthoredBy
\bECC\b|\becc:
\bsub-?agents?\b|\bcode-reviewer\b|\btdd-guide\b
\bContext7\b|\bExa\b|gh search code
\bsee skill:
\bwithout asking\b
```

READMEs are not scanned (so the attribution line may say ECC); only `<topic>.md` files are. The patterns are deliberately narrow: words with legitimate technical uses ("critical CSS", "query planner", "mandatory gofmt", "never mutate props") must not trip the lint, so the house opinions are caught by their specific phrasing, and Reviewer B catches the rest.

### Wiring (`wire.sh`)

- New env var `RULES_DIR` (default `$HOME/.claude/rules`). Only `$RULES_DIR/grid/` is grid-owned.
- Manifest grammar additions, identical in baseline, `machines/<host>.txt`, `.local.txt`:
  - `rules:<pack>`: wire that pack.
  - `-rules:<pack>`: subtract it (overlay escape hatch).
- Default is opt-in: with no `rules:` entry anywhere, no rules are wired (unlike skills/projects there is no legacy wire-all, because rules cost tokens).
- Teardown: remove every symlink under `$RULES_DIR/grid` whose target is under `GRID_DIR`, then delete now-empty directories under `$RULES_DIR/grid`. Nothing outside `$RULES_DIR/grid` is touched; real files there are never removed or overwritten (skipped + manifest row).
- Wire: for each wired pack with a dir `rules/<pack>`, `mkdir -p $RULES_DIR/grid/<pack>` and `ln -sfn` each `*.md` except `README.md`. A `rules:<pack>` with no matching dir prints a warning to stderr, adds a `skipped` manifest row, and does not fail.
- `.wired.manifest` rows: `rule<TAB><pack>/<topic>.md<TAB><source path><TAB>wired|skipped<TAB><reason>`.
- `--check` gains a third kind, `rules`: wire into a temp `RULES_DIR`, diff `relpath -> target` lines (recursive) against the live one, same rules as skills/agents (real files shadowing are not drift).
- `catalog.sh` and `sources.sh` add `rules:*|-rules:*) continue ;;` next to their `project:` skips so `SKILLS.md`/`SOURCES.md` stay unchanged.

### Emitters (`rules.py emit`)

```
python3 scripts/rules.py emit --target cursor|agents-md|gemini-md \
    --project DIR --packs sql,bash [--check] [--max-bytes N]
```

- `--packs` is required (comma list); unknown pack is exit 2. Output is deterministic: packs and files sorted in C locale, no timestamps.
- `--check`: write nothing; exit 1 if `emit` would change anything.
- Cursor: `DIR/.cursor/rules/grid-<pack>-<topic>.mdc`:

```
---
description: BigQuery
globs: ["**/*.sql"]
alwaysApply: false
---
<!-- the-grid:rules generated from rules/sql/bigquery.md; do not edit -->
# BigQuery
...body unchanged...
```

  - `description` = the rule's `# Title`; `globs` = the `paths` list, braces expanded, rendered as a JSON-style list (the shape ECC's Cursor rules use).
  - A `grid-*.mdc` file carrying the marker line that is not in the current set is deleted. Files without the marker are never touched.
- agents-md / gemini-md: one block in `DIR/AGENTS.md` (Codex and OpenCode both read it) or `DIR/GEMINI.md` (project root), created if missing:

```
<!-- BEGIN the-grid rules (generated by scripts/rules.py; edits inside are overwritten) -->
## Coding rules (the-grid)

Apply each rule only when working on files matching its globs.

### sql / bigquery (applies to: `**/*.sql`)
...body with the H1 removed...
<!-- END the-grid rules -->
```

  - The block is replaced between the markers; everything outside is preserved byte-for-byte. Exactly one BEGIN and one END or the command exits 2 without writing.
  - Block size over `--max-bytes` (default 12288) exits 2 with a message to choose fewer packs. These files are always loaded, so the cap is the budget.
  - Emitting with an empty selection removes the block; if the file then contains nothing else it is deleted.

## Token budget

- Idle cost (nothing touched): 0 for all targets except agents-md/gemini-md, where the block is always loaded (cap 12 KB, about 3k tokens, opt-in per project).
- Claude/Cursor cost is paid per matching file touched: at most 9 KB (about 2.3k tokens) per pack. Editing a `.tsx` file with `typescript`, `web` and `react` wired can load three packs, worst case 27 KB (about 7k tokens); packs are written to keep real totals near 15 KB. `rules.py list` prints per-pack bytes so this is visible.

## Relation to issue #5 (stack overlays)

- Stack overlays inject text into a composed agent's identity at compose time; rule packs deliver conventions to any session by file path. Same need (stack knowledge), different mechanism.
- Conventions belong in rules: path-scoped, harness-neutral, loaded only when relevant. The `stack.yaml` fragments plan would make them always-on and Claude-agent-only.
- Result: #5 is superseded for conventions. The five stubs stay (they still name stack composition for agents) and each gets a one-line comment naming its rule packs. `docs/rules.md` carries the mapping.

| Stack stub | Rule packs |
|---|---|
| lamp | php, sql, bash |
| wordpress | wordpress, php |
| data-engineering | sql, dbt, python, bash |
| modern-frontend | typescript, web, react |
| astro | typescript, web |

## Review process for pack content (applies to every content task group)

Gareth has no opinions on unfamiliar languages, so content rests on community consensus, with two independent checks per PR:

- Reviewer A, source fidelity: for each rule file, every bullet traces to the cited source in the pack README or is a direct tool-config consequence of it. Output: list of untraceable bullets (must-fix) and URLs that failed to load.
- Reviewer B, opinion and overbuild: flags any bullet that is personal taste, a single-vendor preference presented as universal, a workflow mandate (tests/coverage/review/agents), or duplicated across files or other packs; flags files over 60% of the cap with low bullet density. Output: must-fix and nice-to-fix lists.
- Each reviewer is a separate fresh subagent (Opus) given only the pack files, README and the check above, not the author's reasoning. Both outputs are pasted into the PR body; all must-fix items are resolved before the PR is marked ready.

## Starting sources per pack (authors must fetch and confirm each URL before citing)

| Pack | Primary sources |
|---|---|
| sql | dbt SQL style guide (docs.getdbt.com/best-practices/how-we-style/2-how-we-style-our-sql); sqlstyle.guide; BigQuery best practices (cloud.google.com/bigquery/docs/best-practices-performance-overview, .../best-practices-costs); BigQuery parameterized queries; GoogleSQL query syntax reference |
| dbt | docs.getdbt.com/best-practices (how we structure, how we style, best-practice workflows); docs.getdbt.com/docs/build/data-tests; docs.getdbt.com/docs/build/incremental-models; dbt project configs reference |
| bash | Google Shell Style Guide (google.github.io/styleguide/shellguide.html); ShellCheck wiki (shellcheck.net/wiki); Greg's Wiki BashGuide and BashPitfalls (mywiki.wooledge.org); GNU Bash manual |
| terraform | developer.hashicorp.com/terraform/language/style; .../modules/develop/structure; .../manage-sensitive-data; .../state; Google Cloud Terraform best practices (cloud.google.com/docs/terraform/best-practices) |
| django | Django docs: coding style (internals/contributing/writing-code/coding-style), topics/security, howto/deployment/checklist, topics/db/queries, topics/migrations |
| flask | Flask docs: patterns/appfactories, blueprints, web-security, config, testing |
| laravel | laravel.com/docs: structure, eloquent, validation, authorization, pint; PSR-12 |
| wordpress | developer.wordpress.org/coding-standards/wordpress-coding-standards/php; developer.wordpress.org/apis/security (validation, sanitising, escaping, nonces); wpdb::prepare reference; Plugin Handbook |
| python | PEP 8, PEP 257, PEP 484; docs.python.org subprocess security considerations; pytest docs; ruff docs |
| typescript | typescriptlang.org TSConfig reference and Handbook; Google TypeScript Style Guide; typescript-eslint docs |
| web | MDN (HTML, CSS, CSP); web.dev Core Web Vitals; WCAG 2.2; OWASP Secure Headers / CSP cheat sheets |
| react | react.dev: Rules of React, You Might Not Need an Effect, Choosing the State Structure, Server Components; testing-library.com guiding principles |
| vue | vuejs.org style guide, security guide, performance, testing guide |
| php | PSR-12 (php-fig.org); php.net security manual; PHP The Right Way; OWASP PHP cheat sheet |
| ruby | rubystyle.guide; guides.rubyonrails.org (security, active_record_querying, testing); RuboCop docs |
| golang | Effective Go; Go Code Review Comments; Google Go Style Guide; pkg.go.dev/testing |
| rust | Rust API Guidelines; doc.rust-lang.org style guide and book; Clippy lint docs; RustSec / cargo-audit |

Tier 2 packs additionally read `repos/ecc/rules/<pack>/*.md` as raw material and keep only what a cited community source also supports.

## Pack inventory (file list, path scopes, budget)

Per-file cap 4 KB, per-pack cap 9 KB (lint-enforced). Target sizes are lower. Topics are `style`, `patterns`, `security`, `testing` unless the table says otherwise. Paths shown are intent; authors may tighten but never widen to `**/*` or equivalents.

| Pack | Tier | Files | Path scope (summary) |
|---|---|---|---|
| sql | 1 | style, bigquery, safety | `**/*.sql` |
| dbt | 1 | models, schema-tests, project | models: `**/{models,macros,snapshots,analyses}/**/*.sql`; schema-tests: `**/models/**/*.{yml,yaml}`, `**/seeds/**/*.{yml,yaml}`; project: `**/{dbt_project,packages,profiles,selectors}.yml` |
| bash | 1 | style, safety, portability | `**/*.{sh,bash}` |
| terraform | 1 | style, modules, safety | `**/*.{tf,tfvars}`; safety also `**/.terraform.lock.hcl` |
| django | 1 | structure, orm, security | `**/{manage,apps,urls,views,admin,forms,serializers,models,managers,middleware}.py`, `**/settings{,/*}.py`, `**/migrations/*.py` (per file as fits) |
| flask | 1 | structure, security | `**/{app,wsgi,routes,views,extensions,config}.py`, `**/blueprints/**/*.py` (heuristic: Flask has no distinctive file names) |
| laravel | 1 | structure, eloquent, security | `**/app/Http/**/*.php`, `**/app/Models/**/*.php`, `**/routes/**/*.php`, `**/database/**/*.php`, `**/config/**/*.php`, `**/resources/views/**/*.blade.php` |
| wordpress | 1 | standards, security, structure | `**/wp-content/**/*.php`, `**/{functions,wp-config}.php`, `**/{theme,block}.json` |
| python | 2 | style, security, testing, fastapi | `**/*.py{,i}`; testing: `**/{test_*,*_test,conftest}.py`; fastapi: `**/{routers,api}/**/*.py`, `**/{main,dependencies}.py` |
| typescript | 2 | style, patterns, testing | `**/*.{ts,tsx,js,jsx,mjs,cjs,mts,cts}`; testing: `**/*.{test,spec}.*` |
| web | 2 | style, performance, security | `**/*.{css,scss,sass,less,html,astro,vue,svelte,tsx,jsx}` |
| react | 2 | hooks, patterns, security, testing | `**/*.{tsx,jsx}`; testing: `**/*.{test,spec}.{tsx,jsx}` |
| vue | 2 | style, patterns, security, testing | `**/*.vue`; testing: `**/*.{test,spec}.{ts,js}` |
| php | 2 | style, patterns, security, testing | `**/*.php`, `**/composer.json`; testing: `**/tests/**/*.php`, `**/*Test.php` |
| ruby | 2 | style, patterns, security, testing | `**/*.{rb,rake}`, `**/{Gemfile,config.ru}`, `**/*.gemspec`; testing: `**/{spec,test}/**/*.rb` |
| golang | 2 | style, patterns, security, testing | `**/*.go`, `**/go.{mod,sum}`; testing: `**/*_test.go` |
| rust | 2 | style, patterns, security, testing | `**/*.rs`, `**/Cargo.{toml,lock}`; testing: `**/{tests,benches}/**/*.rs` |

Stripped from ECC when adapting (these are the house opinions the lint guards):

- "Immutability CRITICAL / never mutate" sections. Language-native facts stay (Rust `let` vs `let mut`, React "do not mutate state", Go value receivers) phrased as the language's own convention.
- 80% coverage, per-layer coverage targets, mandatory TDD, E2E-required.
- Auto-spawn planner/reviewer/tdd agents, "without asking", forced web/GitHub/Context7/Exa search before coding.
- `includeCoAuthoredBy`, `ecc:*` agent names, "See skill: ..." pointers, Claude Code hook advice (`hooks.md`), `web/design-quality.md`.

## Decisions

- Decided: rule files stay plain Claude rules (frontmatter `paths:` only); Claude wiring symlinks them uncompiled, because that is the verified shape and avoids a compile step with a stale-output failure mode.
- Decided: no `description` or `applies_to` in rule frontmatter; the Cursor description is the H1 title, and there is no per-harness filter (every rule is plain markdown that works anywhere; YAGNI).
- Decided: pack metadata lives in a flat `pack.yaml` parsed by a strict hand-written reader, not PyYAML, so `rules.py` and the gate work on any machine without the agent-factory venv.
- Decided: pack READMEs are never wired, because any `.md` in the rules dir loads on every session.
- Decided: the wired layout is real directories holding per-file symlinks (`$RULES_DIR/grid/<pack>/<file>.md`), not a directory symlink, so `README.md` can be excluded.
- Decided: `rules:<pack>` / `-rules:<pack>` in the existing manifest files, no new manifest file, because baseline/overlay layering is the established tier mechanism.
- Decided: rules are opt-in with no legacy wire-all fallback, because they inject context (project rule: token cost must be opt-in).
- Decided: the unit of wiring is the pack, not the file, to keep the grammar and `--check` simple.
- Decided: no always-on common layer; lint rejects any rule without a non-trivial `paths:`. A tiny universal layer is not justified: ECC's common layer is where its house opinions live, and nothing universal is needed that CLAUDE.md does not already carry.
- Decided: per-file cap 4096 bytes, per-pack cap 9216 bytes, because a file read pulls in every matching file and multi-pack stacks (ts + web + react) stack up.
- Decided: lint is a gate check (`scripts/gate.sh`) running on every commit; URL liveness is opt-in (`--check-urls`), never in the gate, because the gate must work offline.
- Decided: the opinion denylist is a data file `rules/denylist.txt`, scanned only in rule files (not READMEs), because reviewers should read and extend it without touching Python.
- Decided: reject zero-width and bidi-control characters in all pack files, because rule text is injected into the model's context and hidden text is an injection vector.
- Decided: tier 2 attribution = `adapted_from` in `pack.yaml`, the literal line `Adapted from affaan-m/ECC (MIT)` in the pack README, and the MIT notice plus per-pack list in `rules/THIRD_PARTY_NOTICES.txt` (a `.txt` so Claude never loads it).
- Decided: drop every ECC `hooks.md` and `web/design-quality.md`; hook advice belongs to workstream 6 and design taste is not consensus content.
- Decided: keep ECC's `python/fastapi.md` as `fastapi.md` in the python pack, narrowly path-scoped, because FastAPI is a mainstream Python web stack with community-documented conventions and ECC already has the content.
- Decided: Cursor `globs` is emitted as a JSON-style list with braces expanded, copying the shape ECC's shipped Cursor rules use (the only verified source in the repo); the HUMAN smoke-test task confirms Cursor loads them.
- Decided: Codex and OpenCode share one target, `agents-md`; Gemini is `gemini-md` writing root `GEMINI.md` (Gemini CLI's default context file); the HUMAN task confirms against the installed CLI. ECC's `.gemini/GEMINI.md` is not copied.
- Decided: emitters take an explicit `--packs` list rather than reading the manifest, because they run per project and the manifest is per machine.
- Decided: the AGENTS.md/GEMINI.md block is capped at 12288 bytes and fails rather than truncating, because silent truncation would drop rules without notice.
- Decided: `rules.py` is one Python stdlib file with three subcommands, no package, no classes beyond a small dataclass; Python 3.8-compatible syntax (macOS system Python).
- Decided: tests use temp dirs and `RULES_DIR`/`GRID_DIR` overrides; `tests/helpers/setup.bash` gets a sandboxed `RULES_DIR` and the tripwire checks it against the real `~/.claude`.
- Decided: issue #5 is closed as superseded; stack stubs get a comment only. No `compose.py` change, because mapping stacks to packs in code would be speculative until agents need it.
- Decided: workstream 11 consumes `rules.py emit`; this change does not touch `~/.codex`, `~/.gemini` or `~/.config/opencode`.
- Decided: `rules.py list` is the single source for pack inventory and sizes; docs link to it instead of embedding a table, so parallel content PRs do not collide on a shared doc.
- Decided: each content task group is one PR covering 2-3 related packs with both reviews pasted into the PR body; the packs in a group are independent of other groups, so groups can run in parallel after group 1.
- Decided: no pack is added to the maintainers' baseline by the loop; choosing wired packs is personal curation (untracked file), done in the HUMAN task. The tracked example files only carry commented examples.
