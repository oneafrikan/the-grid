# Rule packs

Rule packs are short, path-scoped coding conventions kept in `rules/<pack>/`. A rule
loads only when the harness reads or edits a file matching its `paths:` globs, so an
unused pack costs nothing. Nothing is wired by default: you opt in per machine or per
project.

Claude Code loads `.claude/rules/**/*.md` natively and honours `paths:` frontmatter. The
other harnesses have no path scoping that the-grid relies on, so the same source is
rendered into their own formats.

## The four outputs

One source (`rules/<pack>/<topic>.md`), four ways to consume it:

| Output | Produced by | Lands in | Loaded |
|---|---|---|---|
| Claude Code | `wire.sh` (`rules:<pack>` manifest entry) | `$RULES_DIR/grid/<pack>/<topic>.md` (symlinks; default `RULES_DIR=~/.claude/rules`) | when a file matching `paths:` is touched |
| Cursor | `rules.py emit --harness cursor` | `<out>/grid-<pack>-<topic>.mdc` (default `.cursor/rules`) | per file, by the `globs` in each `.mdc` |
| Codex, OpenCode | `rules.py emit --harness agents-md` | one managed block in `AGENTS.md` | always (no path scoping) |
| Gemini CLI | `rules.py emit --harness gemini` | one managed block in `GEMINI.md` | always (no path scoping) |

For an active harness (`harness:<name>`), `wire.sh` makes the Codex, OpenCode and Gemini calls itself, into the global instruction file you created; see "Rules delivery" in `docs/harnesses.md`.

## `rules:<pack>` manifest grammar

`rules:<pack>` and `-rules:<pack>` go in the same untracked files as skills:
`baseline-submodules.txt` (every machine) and `machines/<host>.txt` (one machine). Seed
them from `baseline-submodules.example.txt` and `machines/example.txt`.

```
rules:sql            # wire the sql pack
rules:bash
-rules:wordpress     # overlay only: un-gate a pack the baseline wires (a subtraction always wins)
```

- Opt-in: with no `rules:` entry anywhere, nothing is wired and `RULES_DIR` is not created.
- The unit is the pack. `wire.sh` symlinks each `rules/<pack>/*.md` except `README.md` to
  `$RULES_DIR/grid/<pack>/`. Only `$RULES_DIR/grid/` is grid-owned; a real file there is
  never overwritten.
- An unknown pack, or a name that is not lowercase kebab-case, warns on stderr, is
  recorded as a `skipped` `rule` row in `.wired.manifest`, and does not fail the wire.
- `bash scripts/wire.sh --check` also reports rules drift.
- `GRID_DRY_HOME` forces `RULES_DIR` under the dry home, so a dry run never reaches the
  real `~/.claude/rules`.

Wire, then re-run after any change:

```bash
bash scripts/wire.sh
```

## Pack inventory

Packs, tiers, file counts and byte sizes change as packs land; the inventory is generated,
not listed here.

```bash
python3 scripts/rules.py list
```

Output columns: `pack  tier  files  bytes  summary`, sorted in C locale. Check the format and
caps with `python3 scripts/rules.py lint`; the commit gate runs it.

## Token cost

- Idle cost is 0 for Claude Code and Cursor: a rule is read only when a matching file is touched.
- The cost is per matching file touched, at most 9216 bytes (about 2.3k tokens) per pack
  and 4096 bytes per rule file.
- Packs co-load. Editing a `.tsx` file with `typescript`, `web` and `react` wired can load
  all three, worst case about 27 KB (about 7k tokens); the real total is lower because
  `web` is scoped per file and only its security file matches `.tsx`. Every `dbt` model
  file also loads `sql`, and PHP framework files load `php` plus `laravel` or `wordpress`.
  `rules.py list` shows the sizes.
- `agents-md` and `gemini` blocks are always loaded. The block is capped at 12288 bytes
  (about 3k tokens); a larger selection is refused, not truncated.
- Wire the packs for languages you actually use on that machine.

## Emit interface

`rules.py emit` is the only rule emitter in the-grid. It is the contract the
`multi-harness` change specifies for rule output (that change builds no rule emitter of its
own and calls this one with its own `--out` paths). `rules.py` knows no harness home
locations: the caller picks `--out`.

```bash
python3 scripts/rules.py emit --harness cursor|agents-md|gemini --packs sql,bash [--out PATH] [--check] [--root DIR]
```

| Flag | Meaning |
|---|---|
| `--harness` | required. `cursor` (Cursor `.mdc` files), `agents-md` (Codex, OpenCode), `gemini` (Gemini CLI) |
| `--packs` | required comma list; `""` = empty selection (removes previous output). Unknown pack = exit 2 |
| `--out` | where to write. Default, relative to the current directory: `cursor` -> `.cursor/rules` (a directory); `agents-md` -> `AGENTS.md`; `gemini` -> `GEMINI.md` (files). Any path is accepted, including home-level files; missing parent dirs are created |
| `--check` | write nothing; exit 1 if a run would change anything |
| `--root` | the-grid checkout whose `rules/` is read (default: `GRID_DIR`, else the repo containing the script) |

- Exit codes: 0 done or no drift; 1 drift under `--check`; 2 usage or refusal (unknown
  harness or pack, unbalanced markers, block over cap, `--out` of the wrong type such as an
  existing file for `cursor`). On exit 2 nothing is written.
- Stdout: one line per change, `wrote <path>` or `removed <path>`; nothing when up to
  date. Errors go to stderr.
- Output is deterministic and idempotent: packs and files sorted in C locale, no timestamps.
- `cursor`: one `grid-<pack>-<topic>.mdc` per rule, with `description` (the rule's H1),
  `globs` (the `paths` list, braces expanded, as a JSON-style list) and `alwaysApply: false`.
  A `grid-*.mdc` carrying the generated marker that is no longer in the selection is
  deleted; files without the marker are never touched.
- `agents-md` and `gemini`: one block between
  `<!-- BEGIN the-grid rules ... -->` and `<!-- END the-grid rules -->`, each rule under
  `### <pack> / <topic> (applies to: ...)`. Text outside the markers is preserved
  byte-for-byte; the file is created if missing. Exactly one marker pair or the command
  exits 2. An empty selection removes the block, and deletes the file if nothing else
  remains. The two harnesses produce the same block.

Whether Cursor, Gemini CLI and Codex load these outputs as expected has not been checked
in the real tools yet (task 13 of the rule-packs change).

## Writing or adapting a pack

Authoring standards, the rule file format, `pack.yaml`, the README Sources table, size caps
and the two-reviewer procedure are in [`rules/README.md`](../rules/README.md). A pack that
passes `python3 scripts/rules.py lint` is well formed; reviewers check source fidelity and
overbuild.

## Tier 2 attribution

Tier 1 packs are written fresh from community style guides. Tier 2 packs are adapted from
[affaan-m/ECC](https://github.com/affaan-m/ECC) (MIT), with its house opinions (mandatory
TDD, coverage targets, "never mutate", auto-spawned agents) stripped. A tier 2 pack must have:

- `adapted_from` in its `pack.yaml`;
- the literal line `Adapted from affaan-m/ECC (MIT)` in its pack `README.md`;
- its name under `Adapted packs` in `rules/THIRD_PARTY_NOTICES.txt`, which also holds the full MIT notice.

`rules.py lint` fails a tier 2 pack that lacks any of these (`E_ATTRIBUTION`).

## Stack stubs and rule packs

The stack stubs in `agent-factory/stacks/` stay as agent-composition stubs (`fragments: []`).
Conventions for each stack live in rule packs, which load by file path in any session and
any harness, instead of being injected always-on into one composed agent. This supersedes
the conventions part of issue #5 (stack overlays).

| Stack stub | Rule packs |
|---|---|
| lamp | php, sql, bash |
| wordpress | wordpress, php |
| data-engineering | sql, dbt, python, bash |
| modern-frontend | typescript, web, react |
| astro | typescript, web |

The mapping is documentation only: `compose.py` does not read it.

## Effect on model behaviour

Effect of packs on model behaviour: unmeasured (see task 13.5 of the rule-packs change).
