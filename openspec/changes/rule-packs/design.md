## Context

- Claude Code loads `.claude/rules/**/*.md` (project) and `~/.claude/rules/**/*.md` (user), recursively. Frontmatter `paths:` (glob list, brace expansion allowed) makes a rule load only when Claude reads or edits a matching file. No `paths:` means always loaded. ECC ships exactly this shape.
- Verified: Claude Code follows symlinked rule files, and user-level rules (`~/.claude/rules/`) load without an approval prompt. Wiring by symlink is therefore safe.
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
  - Cursor: `rules.py emit --harness cursor` writes `.cursor/rules/grid-<pack>-<topic>.mdc`.
  - Codex/OpenCode/Gemini: `rules.py emit --harness agents-md|gemini` writes one managed block.
- Claude wiring is tiered by the manifest (opt-in); emitters take an explicit `--packs` list and `--out` target, so the caller (a person in a project, or `multi-harness` for home-level files) chooses scope.
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
- A glob must not start with `/`, contain `..`, or be effectively always-on: `E_PATHS`. Effectively always-on means the last path segment, after removing the characters `*?[]{},.`, is empty (this rejects `*`, `**`, `**/*`, `**/*.*`, `**/**`).
- After the frontmatter: a first line `# <Title>` (the title becomes the Cursor `description`), then only the line shapes in the `E_STYLE` row below.
- Brace expansion `{a,b}` is allowed in globs, with these limits (all `E_PATHS`): no nested braces, no empty alternative (`{,x}`), at most 2 brace groups per glob. Write `**/*.py` and `**/*.pyi` as two entries rather than `**/*.py{,i}`. Claude consumes braces natively; the Cursor emitter expands them left to right as a cartesian product (`*.{test,spec}.{tsx,jsx}` becomes four globs), in source order, duplicates dropped.

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
| `E_PATHS` | empty `paths:`, or a glob that is absolute, contains `..`, is effectively always-on, or breaks the brace limits |
| `E_TITLE` | no `# Title` first line after frontmatter |
| `E_STYLE` | after the title, a non-blank line that is not (a) a `##`/`###` heading, (b) a bullet starting `- `, (c) a continuation of a bullet (starts with two spaces), or (d) inside a fenced code block; a second `# ` heading; a bullet (with its continuation lines) over 240 characters; a fenced block over 10 lines or an unclosed fence. This keeps rules as short directives: no prose paragraphs, no block quotes, no cross-reference lines |
| `E_FILE_SIZE` | rule file over 4096 bytes |
| `E_PACK_SIZE` | sum of a pack's rule files over 9216 bytes |
| `E_OPINION` | any regex in `rules/denylist.txt` matches any single line of a rule file (Python `re` syntax, `re.IGNORECASE`, searched per line so `^` anchors work) |
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
\.\./common\b|\bextends \[?common/
^- *(you|we|it is|it's|consider|try|ideally|maybe|perhaps|should)\b
\b(might want to|may want to|ideally|perhaps)\b
```

- The `\.\./common` pattern catches ECC's "This file extends common/..." lines; the-grid ships no `common` layer, so such a pointer would dangle.
- The last two patterns reject hedged bullets: rules are directives ("Use X"), not suggestions, because hedged wording is followed less reliably and wastes tokens.

READMEs are not scanned (so the attribution line may say ECC); only `<topic>.md` files are. The patterns are deliberately narrow: words with legitimate technical uses ("critical CSS", "query planner", "mandatory gofmt", "never mutate props") must not trip the lint, so the house opinions are caught by their specific phrasing, and Reviewer B catches the rest.

### Pack authoring template (becomes `rules/README.md`, task 1.2)

Authoring standards. Lint enforces the starred ones; Reviewer B checks the rest.

1. Each bullet is one directive: starts with an imperative verb, names one concrete construct in backticks (function, flag, config key, keyword), and gives the reason in at most one short clause. Maximum 240 characters (*).
2. Write only what changes model output: non-default behaviour, easy-to-miss pitfalls, tool or config consequences. Omit advice a competent model follows unprompted ("use descriptive names", "handle errors", "keep functions small", "write tests").
3. State the positive form first (`Use X for Y`). Use "never" only for a hazard, and name the hazard in the bullet.
4. Use `When <trigger>, <action>` for conditional rules. Name a specific tool only if its cited source does; otherwise write "the project's formatter".
5. Allowed line shapes are `##`/`###` headings, bullets, and at most a few fenced snippets of at most 10 lines (*). No prose paragraphs or block quotes (*), and no pointers to other rules, skills or agents (denylist).
6. One topic per file, scoped to the narrowest `paths:` where its bullets apply. Two files in one pack with identical `paths:` is a smell; a bullet that only concerns CSS does not belong in a file that loads on `.tsx`.
7. A directive appears once across all packs. If it applies to two stacks, keep it in the more general pack (for example `sql`, not `dbt`) and rely on both loading.
8. Size targets: 1.5-2.5 KB per file and at most 6 KB per tier 1 pack. The 4096 and 9216 byte caps are ceilings (*), not targets.
9. No hedging, no workflow mandates (tests, coverage, review, commits, agents), no house opinions; every bullet traces to a cited source (README Sources table (*) and Reviewer A).

Rule file skeleton (the `Good`/`Bad` lines are illustrative, not rules):

```markdown
---
paths:
  - "**/*.sql"
---
# BigQuery

## Cost
- Name the columns you need; `SELECT *` bills every column read.
- Filter on the partition column in `WHERE` so BigQuery prunes partitions.
- Set `require_partition_filter` on large partitioned tables so unfiltered scans fail.
```

```
Good: Use `ref()` or `source()` for every table reference in a model; hard-coded schema names break lineage.
Bad:  You should try to write clean, readable SQL with meaningful names.   (hedged, generic, no construct)
```

Pack README skeleton: as in "Pack README.md" above. `pack.yaml` skeleton: as in "pack.yaml" above.

### Wiring (`wire.sh`)

- New env var `RULES_DIR` (default `$HOME/.claude/rules`; when `GRID_DRY_HOME` is set, foundations#8 forces it to `$GRID_DRY_HOME/.claude/rules`, ignoring any inherited value). Only `$RULES_DIR/grid/` is grid-owned.
- Manifest grammar additions, identical in the baseline (path from `GRID_BASELINE`, introduced by `foundations`), `machines/<host>.txt`, `.local.txt`. The `rules:*` and `-rules:*` cases go in `load_manifest` directly after the `project:*`/`-project:*` cases, before the generic `-*/*`, `-*`, `*/*`, `*` cases:
  - `rules:<pack>`: wire that pack.
  - `-rules:<pack>`: subtract it (overlay escape hatch).
- Default is opt-in: with no `rules:` entry anywhere, no rules are wired (unlike skills/projects there is no legacy wire-all, because rules cost tokens).
- Teardown: remove every symlink under `$RULES_DIR/grid` whose target is under `GRID_DIR`, then delete now-empty directories under `$RULES_DIR/grid`. Nothing outside `$RULES_DIR/grid` is touched; real files there are never removed or overwritten (skipped + manifest row).
- Wire: for each wired pack with a dir `rules/<pack>`, `mkdir -p $RULES_DIR/grid/<pack>` and `ln -sfn` each `*.md` except `README.md`. A `rules:<pack>` with no matching dir prints a warning to stderr, adds a `skipped` manifest row, and does not fail.
- `.wired.manifest` rows: `rule<TAB><pack>/<topic>.md<TAB><source path><TAB>wired|skipped<TAB><reason>`.
- `--check` gains a third kind, `rules`: the throwaway run sets only `GRID_DRY_HOME=$tmp/home` and reads `$tmp/home/.claude/rules`, diff `relpath -> target` lines (recursive) against the live one, same rules as skills/agents (real files shadowing are not drift).
- `catalog.sh` and `sources.sh` add the generic typed-entry skip `*:*|-*:*) continue ;;` after their `project:` skips so `SKILLS.md`/`SOURCES.md` stay unchanged by `rules:` and any other typed line.

### Emitters (`rules.py emit`) — the interface other changes call

This command is the only rule emitter in the-grid. `multi-harness` calls it; it does not build its own rule output or a `dist/rules/` tree.

```
python3 scripts/rules.py emit --harness cursor|agents-md|gemini --packs sql,bash [--out PATH] [--check] [--root DIR]
```

| Flag | Meaning |
|---|---|
| `--harness` | required. `cursor` (Cursor `.mdc` files), `agents-md` (Codex, OpenCode), `gemini` (Gemini CLI) |
| `--packs` | required comma list; `""` = empty selection (removes previous output). Unknown pack = exit 2 |
| `--out` | where to write. Default, relative to the current directory: `cursor` -> `.cursor/rules` (a directory); `agents-md` -> `AGENTS.md`; `gemini` -> `GEMINI.md` (files). Any path is accepted, including home-level files such as a user-level `AGENTS.md`; missing parent dirs are created. `rules.py` knows no harness home locations; the caller chooses them |
| `--check` | write nothing; exit 1 if a run would change anything |
| `--root` | the-grid checkout whose `rules/` is read (default: `GRID_DIR`, else the repo containing the script); same flag as `lint` |

- Exit codes: 0 done / no drift; 1 drift under `--check`; 2 usage or refusal (unknown harness or pack, unbalanced markers, block over cap, `--out` of the wrong type such as an existing file for `cursor`). On exit 2 nothing is written.
- Stdout: one line per change, `wrote <path>` or `removed <path>`; nothing when already up to date. Errors go to stderr.
- Output is deterministic: packs and files sorted in C locale, no timestamps.
- `cursor`: one file per rule, `<out>/grid-<pack>-<topic>.mdc`:

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
- `agents-md` / `gemini`: one block in the `--out` file (`AGENTS.md` is read by Codex and OpenCode; `GEMINI.md` by Gemini CLI), created if missing:

```
<!-- BEGIN the-grid rules (generated by scripts/rules.py; edits inside are overwritten) -->
## Coding rules (the-grid)

Apply each rule only when working on files matching its globs.

### sql / bigquery (applies to: `**/*.sql`)
...body with the H1 removed...
<!-- END the-grid rules -->
```

  - The block is replaced between the markers; everything outside is preserved byte-for-byte. Exactly one BEGIN and one END or the command exits 2 without writing.
  - Block size over 12288 bytes (constant `BLOCK_CAP` in `rules.py`, not a flag) exits 2 with a message to choose fewer packs. These files are always loaded, so the cap is the budget.
  - Emitting with an empty selection removes the block; if the file then contains nothing else it is deleted.

## Token budget

- Idle cost (nothing touched): 0 for all targets except `agents-md`/`gemini`, where the block is always loaded (cap 12 KB, about 3k tokens, opt-in per output file).
- Claude/Cursor cost is paid per matching file touched: at most 9 KB (about 2.3k tokens) per pack. Editing a `.tsx` file with `typescript`, `web` and `react` wired can load three packs, worst case 27 KB (about 7k tokens); packs are written to keep real totals near 15 KB (tier 1 packs target 6 KB, authoring standard 8). `web` is scoped per file so only its security file loads on `.tsx`. Overlap that remains by design: every `dbt` model file also loads `sql` (keep generic SQL out of `dbt`), and PHP framework files load `php` plus `laravel`/`wordpress`. `rules.py list` prints per-pack bytes so this is visible.

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

The operator has no opinions on unfamiliar languages, so content rests on community consensus, with two independent checks per PR. The prompts live in the repo as `rules/review-a.prompt.txt` and `rules/review-b.prompt.txt` (created in task 1.2; text below is their contents) so an unattended agent runs them verbatim and never improvises a reviewer brief.

Procedure (run once per content PR, after lint passes):

1. Spawn two reviewers in one message with the Agent tool: `subagent_type: general-purpose`, `model: opus`, a fresh agent each. The prompt is the prompt file with `<PACK_DIRS>` replaced by the PR's pack directories (repo-relative). Add nothing else: no author reasoning, no hints, no expected verdict. They run inside the implementing session, so the loop's per-session `--max-turns`/timeout/cost caps bound them (no extra `claude -p` process). Content issues carry the label `ws:rule-packs`, which raises that session's cap to `MAX_BUDGET_USD=15` to cover the author plus up to six Opus reviewer runs.
2. Output contract, both reviewers: finding lines are `MUST <file>[#n]: <reason>` or `NICE <file>[#n]: <reason>`; the last line is exactly `VERDICT: PASS` (no `MUST`, no `UNTRACED`, no `URL_FAIL`) or `VERDICT: FAIL`.
3. Resolve every `MUST` by rewriting or deleting the bullet. Deleting is always an acceptable resolution; never argue a finding. Re-run only the reviewer that returned FAIL, with a fresh agent and the same prompt. At most 2 re-runs per reviewer.
4. If a reviewer still returns FAIL after 2 re-runs, or a reviewer cannot fetch URLs (WebFetch denied), stop: open the PR as a draft, label it `needs-human`, paste the last outputs, and say which group stopped and why. Do not mark it ready.
5. Paste both final outputs in the PR body under `## Reviewer A (source fidelity)` and `## Reviewer B (opinion and overbuild)`, Reviewer A's per-bullet table inside `<details>`. Mark the PR ready only when both end in `VERDICT: PASS`.

Reviewers are Opus-class agents separate from the Sonnet author; the author does not edit a reviewer's output. The reviews are the only behavioural-quality evidence a pack gets before use: whether a pack changes model output is unmeasured until the HUMAN spot check (task 13.5).

`rules/review-a.prompt.txt` (Reviewer A, source fidelity):

```
You review rule packs for source fidelity. Pack directories: <PACK_DIRS>.
For each pack, read README.md (Sources table) and every other .md file (rule files).
For each rule file, WebFetch every URL on its Sources row. Judge only from the fetched
page text, never from memory. A "bullet" is a line starting "- " plus its indented
continuation lines. A bullet is TRACED when a fetched page states the practice, or a
documented option or default on the page makes the bullet literally true.
Output, in this order:
1. URL_FAIL <url> for every URL that did not load; bullets that depended only on it are UNTRACED.
2. One line per bullet: <file>#<n> TRACED "<quote of at most 15 words>" <url>
   or <file>#<n> UNTRACED - <why>.
3. MUST <file>: <reason> when the Sources row cites something other than official
   documentation, a style guide or a standard of the language or tool (blogs, forums,
   AI summaries and vendor marketing do not count), or when the row belongs to a
   different file.
4. Last line: VERDICT: PASS if there is no UNTRACED, URL_FAIL or MUST line, else VERDICT: FAIL.
Do not suggest additions or edit any file.
```

`rules/review-b.prompt.txt` (Reviewer B, opinion and overbuild):

```
You review rule packs for opinion and overbuild. Pack directories: <PACK_DIRS>.
Read every rule file (every .md except README.md) in them. You may read the other
directories under rules/ to detect duplicates. A "bullet" is a line starting "- "
plus its indented continuation lines. Flag each bullet or file with one code:
B1 workflow mandate (tests, coverage, TDD, code review, commits, PRs, spawning agents,
   searching before coding)                                               MUST
B2 personal taste, or a single vendor or tool preference stated as universal (names a
   formatter, linter, framework or library as required where the language's own
   documentation names none)                                              MUST
B3 absolute "always", "never" or "must" with no hazard stated in the bullet MUST
B4 generic advice any competent model follows unprompted (naming, small functions,
   handle errors, comment code, readability)                              MUST
B5 duplicate of another bullet in the same pack or in any other pack      MUST
B6 not an imperative directive (hedged, explanatory, or a question)       MUST
B7 file over 2458 bytes whose bytes per bullet exceed 200, or a bullet over 240
   characters                                                             NICE
B8 file scoped to paths wider than its bullets apply (for example a CSS-only bullet
   in a file that also loads on .tsx)                                     MUST
Output one line per finding: MUST|NICE <file>#<n>: <code> <reason>. Do not suggest
additions or edit any file. Last line: VERDICT: PASS if there is no MUST line, else
VERDICT: FAIL.
```

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

Per-file cap 4 KB, per-pack cap 9 KB (lint-enforced). Target sizes are lower. Topics are `style`, `patterns`, `security`, `testing` unless the table says otherwise. Paths shown are the union for the pack; scope each file to the narrowest subset where its bullets apply (authoring standard 6), and tighten but never widen to anything `E_PATHS` rejects. Brace limits from the rule file grammar apply, so write `**/*.py` and `**/*.pyi` as two entries.

| Pack | Tier | Files | Path scope (summary) |
|---|---|---|---|
| sql | 1 | style, bigquery, safety | `**/*.sql` |
| dbt | 1 | models, schema-tests, project | models: `**/{models,macros,snapshots,analyses}/**/*.sql`; schema-tests: `**/models/**/*.{yml,yaml}`, `**/seeds/**/*.{yml,yaml}`; project: `**/{dbt_project,packages,profiles,selectors}.yml` |
| bash | 1 | style, safety, portability | `**/*.{sh,bash,bats}`; extensionless scripts with a shebang are not matched (path globs cannot see shebangs), stated in the pack README |
| terraform | 1 | style, modules, safety | `**/*.{tf,tfvars}`; safety also `**/.terraform.lock.hcl` |
| django | 1 | structure, orm, security | structure: `**/{manage,apps,urls,admin,forms}.py`, `**/settings.py`, `**/settings/*.py`; orm: `**/{models,managers}.py`, `**/models/*.py`, `**/migrations/*.py`; security: `**/{settings,urls,views,forms,admin,middleware}.py`, `**/settings/*.py`, `**/views/*.py` |
| flask | 1 | structure, security | `**/{app,wsgi,routes,extensions,config}.py`, `**/blueprints/**/*.py` (heuristic: Flask has no distinctive file names; `views.py` and `models.py` are left to django because they are ambiguous) |
| laravel | 1 | structure, eloquent, security | structure: `**/app/{Http,Providers,Console,Jobs,Events,Listeners}/**/*.php`, `**/{routes,config}/**/*.php`; eloquent: `**/app/Models/**/*.php`, `**/database/**/*.php`; security: `**/app/{Http,Policies,Rules}/**/*.php`, `**/routes/**/*.php`, `**/resources/views/**/*.blade.php` |
| wordpress | 1 | standards, security, structure | `**/wp-content/**/*.php`, `**/{plugins,themes,mu-plugins}/**/*.php`, `**/class-*.php` (WordPress coding standards file naming), `**/{functions,wp-config,uninstall}.php`, `**/{theme,block}.json`. Most plugin and theme repos have no `wp-content/` directory, so the `class-*.php`, `functions.php` and `*.json` globs carry them; the README states the remaining gap |
| python | 2 | style, security, testing, fastapi | `**/*.py`, `**/*.pyi`; testing: `**/{test_*,*_test,conftest}.py`; fastapi: `**/{routers,api}/**/*.py`, `**/{main,dependencies}.py` |
| typescript | 2 | style, patterns, testing | `**/*.{ts,tsx,js,jsx,mjs,cjs,mts,cts}`; testing: `**/*.{test,spec}.*` |
| web | 2 | style, performance, security | style: `**/*.{css,scss,sass,less,html}`; performance: `**/*.{css,scss,sass,less,html,astro,vue,svelte}`; security: `**/*.{html,astro,vue,svelte,tsx,jsx}`. `style` and `performance` stay off `.tsx`/`.jsx` so a React file loads at most `web/security` from this pack |
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
- Decided: no hidden-Unicode check in `rules.py lint`; `vetting`'s `scripts/audit.sh --owned` already scans `rules/` for hidden Unicode in the gate, so a second scanner would duplicate it.
- Decided: tier 2 attribution = `adapted_from` in `pack.yaml`, the literal line `Adapted from affaan-m/ECC (MIT)` in the pack README, and the MIT notice plus per-pack list in `rules/THIRD_PARTY_NOTICES.txt` (a `.txt` so Claude never loads it).
- Decided: drop every ECC `hooks.md` and `web/design-quality.md`; hook advice belongs to `hook-profiles` and design taste is not consensus content.
- Decided: keep ECC's `python/fastapi.md` as `fastapi.md` in the python pack, narrowly path-scoped, because FastAPI is a mainstream Python web stack with community-documented conventions and ECC already has the content.
- Decided: Cursor `globs` is emitted as a JSON-style list with braces expanded, copying the shape ECC's shipped Cursor rules use (the only verified source in the repo); the HUMAN smoke-test task confirms Cursor loads them.
- Decided: Codex and OpenCode share one harness value, `agents-md`; Gemini is `gemini`, default `--out GEMINI.md` (Gemini CLI's default context file name); the HUMAN task confirms against the installed CLI. ECC's `.gemini/GEMINI.md` is not copied.
- Decided: emitters take an explicit `--packs` list rather than reading the manifest, because the caller decides scope (per project by hand, or per machine via `multi-harness`).
- Decided: the AGENTS.md/GEMINI.md block is capped at 12288 bytes and fails rather than truncating, because silent truncation would drop rules without notice.
- Decided: `rules.py` is one Python stdlib file with three subcommands, no package, no classes beyond a small dataclass; Python 3.8-compatible syntax (macOS system Python).
- Decided: tests use temp dirs and `RULES_DIR`/`GRID_DIR` overrides; `tests/helpers/setup.bash` gets a sandboxed `RULES_DIR` and the tripwire checks it against the real `~/.claude`.
- Decided: issue #5 is closed as superseded; stack stubs get a comment only. No `compose.py` change, because mapping stacks to packs in code would be speculative until agents need it.
- Decided: `emit --harness … --packs … [--out PATH] [--check]` is the stable interface `multi-harness` calls; this change never chooses or writes home-level harness locations itself (`~/.codex`, `~/.gemini`, `~/.config/opencode`), and its tests use temp `--out` paths only.
- Decided: `--out` replaces a `--project DIR` flag, so one flag serves project files and home-level files; defaults are relative to the current directory.
- Decided: the block cap is a constant, not a `--max-bytes` flag; no caller needs a different budget (YAGNI).
- Decided: `rules.py list` is the single source for pack inventory and sizes; docs link to it instead of embedding a table, so parallel content PRs do not collide on a shared doc.
- Decided: each content task group is one PR covering 2-3 related packs with both reviews pasted into the PR body; the packs in a group are independent of other groups, so groups can run in parallel after group 1.
- Decided: no pack is added to the maintainers' baseline by the loop; choosing wired packs is personal curation (untracked file), done in the HUMAN task. The tracked example files only carry commented examples.
- Decided: add lint code `E_STYLE` (line shapes, bullet length, fence size) and extend `E_PATHS` (effectively-always-on globs like `**/*.*`, brace limits), because "imperative bullets, no paragraphs" and "path scoped" were stated but unenforced, and prose rules load as context on every touch of a matching file.
- Decided: braces in `paths` are limited (no nesting, no empty alternative, at most 2 groups) and the Cursor emitter expands them as a cartesian product, because `{,i}` style expansion is the least-documented form and the emitter needs a total, testable definition.
- Decided: the denylist also rejects hedged bullets and dangling `common/` pointers (ECC's "This file extends common/..." lines), and is searched per line.
- Decided: the authoring template lives in `rules/README.md` and the two reviewer prompts in `rules/review-a.prompt.txt` and `rules/review-b.prompt.txt` (`.txt` so they are never loaded as rules), because `openspec/changes/` is archived and unattended agents must find the standard and prompts in the repo.
- Decided: Reviewer A must quote a supporting sentence (at most 15 words) for every bullet and treats an unfetched URL as UNTRACED; "direct tool-config consequence" is replaced by "documented option or default on the page makes the bullet literally true". A quote requirement is what makes "I checked" visible in the PR.
- Decided: reviewer output is machine-readable (`MUST`/`NICE` lines, final `VERDICT: PASS|FAIL`); resolution is by rewrite or deletion only; at most 2 re-runs per reviewer, then the PR is left as a draft labelled `needs-human`. Same stop rule if WebFetch is unavailable.
- Decided: Reviewer B's checks are the coded list B1-B8 in its prompt, not a free-form taste judgement; B4 (generic advice the model follows unprompted) is a MUST because such bullets are token cost with no behavioural effect.
- Decided: per-file path scoping inside a pack (web, django, laravel), `views.py` removed from the flask scope, `bats` added to bash, and extra WordPress globs (`class-*.php`, `plugins/themes`), because the original globs either loaded irrelevant rules on `.tsx` or missed most real WordPress repos.
- Decided: pack effect on model behaviour is stated as unmeasured in `docs/rules.md` until the HUMAN spot check (task 13.5) runs.

Integration pass (QA, security and cross-change findings):

- Decided: (G1, F5) `RULES_DIR` is FORCED to `$GRID_DRY_HOME/.claude/rules` when `GRID_DRY_HOME` is set (foundations#8 contract; an inherited `RULES_DIR` is ignored); rule-packs relies on it and does not re-derive it. `--check` reads `$tmp/home/.claude/rules`. Task 2.5's sentinel test exports `RULES_DIR` into the fake real home and asserts it stays untouched.
- Decided: (F8) group 2 depends on foundations#8 (the `GRID_DRY_HOME` task), unconditionally.
- Decided: (G4) rule-packs#2 is the first change in merge order to edit `catalog.sh`/`sources.sh`, so it adds the generic typed-entry skip `*:*|-*:*) continue ;;` after the `project:` case in both, not a `rules:`-specific case; later changes adding `harness:`/`hook:` lines need no edit there. Tested with `rules:`, `-rules:`, `harness:` and `-hook:` lines.
- Decided: (G3) the gate's `rules` check skips loudly (prints a reason, appends `rules` to `SKIPPED`, returns 0) when `python3` or `scripts/rules.py` is absent, matching `run_compose_check`; task 1.3a adds both cases to `tests/test_gate.bats`.
- Decided: (QA10) group 1 depends on vetting#1 (`audit.py`, which scans `rules/` for hidden Unicode); vetting#5 (gate wiring) is merge order only.
- Decided: (QA9) group 2 also depends on hook-profiles#4: it rebases onto that group's `load_manifest` `hook:` cases and the `CLAUDE_CONFIG_DIR` export in `tests/helpers/setup.bash`.
- Decided: (Q2) content groups 6-12 use `WebFetch` (author source checks and Reviewer A), only inside the loop's isolated worker; if `WebFetch` is unavailable or denied, the PR stops as a draft labelled `needs-human`. Pending operator: Q2 — allow WebFetch in the loop worker (only with Q1 isolation); default yes.
- Decided: (Q8) reviewers are Opus: Agent-tool subagents with `model: opus` inside the worker session (not separate `claude -p` calls, because Reviewer A needs `WebFetch` and a `--tools ""` call cannot fetch); content issues are labelled `ws:rule-packs`, which sets the worker's `MAX_BUDGET_USD=15`. Pending operator: Q8 — Opus reviewers allowed with a raised cap of 15 USD for `ws:rule-packs` issues; default yes.
