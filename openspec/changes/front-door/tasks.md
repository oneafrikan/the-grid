# Tasks

All groups: run from the repo root on branch `next`; verify with `bash scripts/gate.sh` unless stated. Never touch real `~/.claude` in tests (use `GRID_DIR`, `SKILLS_DIR`, `AGENTS_DIR` temp dirs). Changes `foundations` and `depersonalise` (and every change before `front-door` in the merge order) are merged to `next` first.

## 1. Generated counts (stamp-counts + gate)

Depends on: foundations#1 (catalog exclusions fixed so the SKILLS.md headline is right).

- [ ] 1.1 New `scripts/stamp-counts.py` (python3 stdlib) per design.md "Generated counts": derive the six values from the committed `SKILLS.md` headline line (regex in design.md) and the `^[[:space:]]*- role:` line count across `agent-factory/examples/*.yaml`; rewrite `<!--count:NAME-->VALUE<!--/count-->` in `README.md`, `README.*.md`, `index.html` (relative to `GRID_DIR`, default repo root); `--check` exits 1 naming the file on drift; exit 2 on an unknown NAME, or on a missing/unparsable headline when any file has markers; exit 0 with no work when no file has markers; idempotent. Comment the regex.
- [ ] 1.2 `scripts/catalog.sh`: after writing the default `$GRID_DIR/SKILLS.md` (not in `--check`, not when an output path argument is given), run `GRID_DIR="$GRID_DIR" python3 "$(dirname "${BASH_SOURCE[0]}")/stamp-counts.py"`. One commented line block; no other change.
- [ ] 1.3 `scripts/gate.sh`: add a `counts` check running `python3 scripts/stamp-counts.py --check` (always runs; it compares committed files only). Update the header comment list.
- [ ] 1.4 New `tests/test_stamp_counts.bats` (temp `GRID_DIR` with a fixture `SKILLS.md` headline, one `agent-factory/examples/x.yaml` with 3 `- role:` lines, `README.md`, `README.ja.md`, `index.html`): stamps all three; second run is a byte-identical no-op; `--check` fails on a stale value and passes after stamping; unknown NAME exits 2; unparsable headline with markers present exits 2; no markers anywhere exits 0; one case copies the real repo `SKILLS.md` into the fixture, stamps a README holding all six markers, and asserts exit 0 and six numeric values (guards against a headline format change).
- [ ] 1.5 `CLAUDE.md` Key files: add `scripts/stamp-counts.py` (one line: counts in README/index.html come from the SKILLS.md headline; catalog.sh restamps them).
- Acceptance: new bats cases pass; `python3 scripts/stamp-counts.py --check` exits 0 on the repo (no markers yet).
- Verify: `bash scripts/gate.sh`

## 2. Doc split: INSTALL, CONTRIBUTING, architecture, roadmap, private projects

Depends on: manifest-lock-install#9 (BOOTSTRAP.md has the install-without-submodules section INSTALL.md links to). Do before group 4. Move text verbatim from today's `README.md`; fix only paths, the clone URL (`https://github.com/oneafrikan/the-grid.git`) and first-person voice. Do not edit README.md in this group.

- [ ] 2.1 New `INSTALL.md` (<= 90 lines): prerequisites (git, bash, python3 for agents, Claude Code, Node >= 20.19 only for openspec-* skills with the `npm install -g @fission-ai/openspec@latest` note), the three paths (one command with `--with-agents`, without it, manual steps), "what it touches" (writes only symlinks into `~/.claude/skills` and `~/.claude/agents`, never overwrites a real dir), Reconciling a machine section (moved), fork-first note, link to `BOOTSTRAP.md` for update/precedence/troubleshooting and to its "Install without submodules" section for `grid install`.
- [ ] 2.2 New `CONTRIBUTING.md`: how I work (issues only, no Discussions), branch from and PR to `next`, run `bash scripts/gate.sh` first, spec-driven for non-trivial changes (3-line OpenSpec pointer to `project-factory/templates/_common/SPECS.md`), rules (every new asset type names its use case; no sponsored content; no personal data; never a paid product), moved sections: Adding a skill directly, Adding a sibling repo as a submodule, Running tests, Checking grid health.
- [ ] 2.3 New `docs/architecture.md`: the factories table as it stands in today's README, the wired/library tiers, "How wire.sh works" (6 steps + env overrides), Repo layout tree (update to include `assets/`, `INSTALL.md`, `CONTRIBUTING.md`, `SECURITY.md`, `CHANGELOG.md`, `scripts/stamp-counts.py`), and a short note that the README mermaid and the index.html SVG must be edited together.
- [ ] 2.4 New `docs/roadmap.md`: Roadmap table and the model-routing paragraph, moved. New `docs/private-projects.md`: Private projects section including the overwrite warning, moved.
- [ ] 2.5 New `tests/test_front_door.bats` (docs part): each new file exists; each has its required top heading; every relative markdown link in the new files resolves to an existing path (skip `http`, `mailto`, anchors); none contains `<your-username>`, `/Users/` or `Gareth's`.
- Acceptance: `tests/lib/bats-core/bin/bats tests/test_front_door.bats` passes; a manual diff shows every README section in the split map has a new home.
- Verify: `bash scripts/gate.sh`

## 3. Trust files

Depends on: 2 (CONTRIBUTING.md exists; this group only tests it).

- [ ] 3.1 New `SECURITY.md`: scope (`wire.sh` and `bootstrap.sh` write to `$HOME` but only symlinks into this repo; submodule code is third-party and unreviewed here; read scripts before running), how to report (GitHub private vulnerability reporting link `https://github.com/oneafrikan/the-grid/security/advisories/new`; do not open a public issue; no email), best-effort acknowledgement within 7 days, no bounty, supported versions (latest tag and `main`), out of scope (vulnerabilities in upstream submodules: report upstream).
- [ ] 3.2 New `CHANGELOG.md` (Keep a Changelog headings): `## [Unreleased]` listing this change's user-visible items in 5 bullets.
- [ ] 3.3 Extend `tests/test_front_door.bats`: SECURITY.md contains the advisory URL and the word "supported" and no `@`-style email; CHANGELOG.md has `## [Unreleased]`; CONTRIBUTING.md names `next` and `bash scripts/gate.sh`.
- Acceptance: new test cases pass.
- Verify: `bash scripts/gate.sh`

## 4. README rewrite (English)

Depends on: 1, 2, 3; foundations#2 (CI green so the badge is honest); depersonalise#4 (status bullet wording). Implements the skeleton, draft copy, quickstart and mermaid in design.md exactly.

- [ ] 4.1 Rewrite `README.md` to 150-180 lines in the block order of the skeleton. Hero sentence verbatim, bold paragraph (no blockquote). Badges: tests (`https://github.com/oneafrikan/the-grid/actions/workflows/tests.yml/badge.svg`), MIT, site link. Status one-liner under badges (exact text in design.md), then an empty `<!-- langs --><!-- /langs -->` line. ASCII banner (content of `the-grid.txt`) in a code fence. Flynn monologue (all 9 lines) + attribution in `## Why "the grid"`.
- [ ] 4.2 Quickstart with the exact command from design.md, prerequisites line, "You should now see" bullets, fork-first note, paste-into-Claude blockquote, "Stop there" line. Counts only via `<!--count:NAME-->` markers; run `python3 scripts/stamp-counts.py` to fill them.
- [ ] 4.3 `## How it works`: mermaid block verbatim from design.md plus the four bullets. `## Docs`: links to USAGE.md, INSTALL.md, BOOTSTRAP.md, SKILLS.md, CONTRIBUTING.md, SECURITY.md, CHANGELOG.md, docs/architecture.md, docs/roadmap.md, docs/model-selection.md, agent-factory/README.md, project-factory/README.md, plus each of `docs/rules.md`, `hooks/README.md`, `CURATION.md` that exists, plus a 3-line spec-driven pointer. Carry over any one-line pointer earlier changes added to today's README (e.g. to `docs/rules.md`) into this list. `## Status`: keep today's candid bullets (rewritten first person, with the personal-config bullet from today's README), replace "No versioning" with "Versioned from v0.1.0; v0.x may still break between tags".
- [ ] 4.4 Fix links in `USAGE.md` / `BOOTSTRAP.md` that point to README sections that moved, and replace the `<your-username>` clone URL in `BOOTSTRAP.md` with `https://github.com/oneafrikan/the-grid.git` (only those edits).
- [ ] 4.5 Extend `tests/test_front_door.bats` (README part): 140-185 lines; `##` headings in skeleton order (`Who it's for`, `Quickstart`, `What you get`, `How it works`, `Why "the grid"`, `Status`, `Docs`); exact hero sentence present once and not inside a `>` line; clone URL line present and no `your-username` in README.md or BOOTSTRAP.md; quickstart line contains `--with-agents`; mermaid fence present; ASCII banner first line (`████████╗`) and `Kevin Flynn` present; no heading matching `ECC|gstack|Why not`; hero line contains neither `Claude Code`, `ECC` nor `gstack`; no bare `[0-9]{2,4} (skills|agents|roles)` outside markers; every relative link resolves; every `<!--count:` name is one of the six keys in design.md.
- Acceptance: test_front_door.bats passes; `python3 scripts/stamp-counts.py --check` exits 0.
- Verify: `bash scripts/gate.sh`

## 5. Site assets script and favicon

Depends on: nothing.

- [ ] 5.1 New `scripts/build-site-assets.sh <source.png> [outdir=assets]` per design.md: ImageMagick check (exit 3 with install hints), `hero.webp` (1600 wide, quality loop down to 50, < 300 KB else exit 4), `og.jpg` (1200x630 cover crop, < 250 KB), metadata stripped. shellcheck-clean, commented, idempotent (second run produces identical bytes).
- [ ] 5.2 New `assets/favicon.svg`: hand-written, < 2 KB, a 3x3 grid glyph using the accent colour `#5b8af0` on `#0d0d0f`.
- [ ] 5.3 New `tests/test_site_assets.bats`: usage error with no args (exit 2); exit 3 path using a PATH with no ImageMagick; when ImageMagick exists (else `skip`), build a synthetic 2816x1536 PNG with `python3` stdlib (zlib gradient), run the script into a temp dir, assert `hero.webp` < 300 KB and `og.jpg` is 1200x630 (`identify`) and a second run leaves identical checksums; assert `assets/favicon.svg` is well-formed XML (`python3 -I -c 'import xml.dom.minidom...'`).
- Acceptance: new bats pass (or skip) on macOS and Ubuntu.
- Verify: `bash scripts/gate.sh`

## 6. HUMAN: render hero and OG assets

Depends on: 5.

- [ ] 6.1 HUMAN: run `bash scripts/build-site-assets.sh the-grid.png` on a machine with ImageMagick; open `assets/hero.webp` and `assets/og.jpg`; judge the crop (wordmark readable at 1200x630, nothing important cut).
- [ ] 6.2 HUMAN: confirm sizes (`ls -l assets/`): hero.webp < 300 KB, og.jpg < 250 KB; commit `assets/hero.webp assets/og.jpg` to `next`.
- [ ] 6.3 HUMAN: copy `the-grid.png` into the private repo (it is the only source for future re-renders; group 7 deletes it from this repo).
- Acceptance: both files committed; sizes within limits; source PNG saved in the private repo.
- Verify: `bash scripts/gate.sh`

## 7. index.html rebuild

Depends on: 1, 4, 6.

- [ ] 7.1 `index.html` `<head>`: title, meta description (<= 160 chars), canonical, SVG favicon link, theme-color, Open Graph set, Twitter set, JSON-LD (all exactly as in design.md). Remove every reference to `the-grid.png`, then `git rm the-grid.png` and delete its line from `scripts/personal-allow-paths.txt`.
- [ ] 7.2 Hero: `<picture>` with `assets/hero.webp` (width 1600, height 873, `fetchpriority="high"`, `alt="the-grid"`), visible `<h1>` with the hero sentence, `<pre><code id="install-cmd">` with the README quickstart command, Copy button (inline JS in try/catch, `hidden` until JS runs, `aria-live` status text), links "View on GitHub", "Star on GitHub" (both to `https://github.com/oneafrikan/the-grid`) and "Quickstart" (`#quickstart`). Delete the visually-hidden H1 CSS and markup.
- [ ] 7.3 Section order per design.md: Who it's for, `id="quickstart"`, Flynn pull-quote band (all lines, attribution), What you get (copy mirrors README), How it works with inline SVG diagram (same nodes as the mermaid), then existing Agents / factories / Specs / Roadmap / Status sections.
- [ ] 7.4 Remove "Key files", "Common commands" and the per-repo Skills listing; replace the latter with one paragraph using count markers and a link to SKILLS.md. Replace every typed count in the remaining text with a `<!--count:NAME-->` marker, then run `python3 scripts/stamp-counts.py`.
- [ ] 7.5 Fix drift: Status bullet uses README wording on personal config; footer becomes "Built by Gareth Knight. MIT. GitHub. Issues." with links; replace "skills Gareth owns" style third-person phrases with first person.
- [ ] 7.6 New `tests/test_landing_page.bats` (parse with `python3 -I` + `html.parser`): exactly one `<h1>`, not inside a visually-hidden class, text equals the README hero sentence; `#install-cmd` text equals the README quickstart command; meta description present and <= 160; canonical, `og:title|description|image|url`, `twitter:card=summary_large_image`, icon link present; JSON-LD parses and has `codeRepository`; at least one `href` to `https://github.com/oneafrikan/the-grid`; no `<script src=` / `<link href=http` to external hosts; `assets/hero.webp` exists and < 300 KB; `index.html` < 100 KB; no `the-grid.png` reference and the file is not tracked; `git grep -l your-username -- . ':!openspec' ':!repos'` prints nothing; Flynn attribution present; no bare `[0-9]{2,4} (skills|agents|roles)` outside markers; `stamp-counts.py --check` passes.
- Acceptance: test_landing_page.bats passes; open `index.html` locally and confirm hero, install command and buttons are visible without scrolling at 1280x800 and 390x844 (note result in the PR body).
- Verify: `bash scripts/gate.sh`

## 8. README translation pipeline

Depends on: 4.

- [ ] 8.1 New `scripts/lib/readme-locales.txt` (9 tab-separated lines, order and names per design.md), `scripts/lib/readme-hash.sh` (function `readme_source_hash <file>` implementing the normalisation and sha256 with `shasum -a 256` or `sha256sum`).
- [ ] 8.2 New `docs/translation-prompt.md`: the translation rules from design.md as a prompt (translate prose only; untouched list; keep markers/links/fences; output only the translated README body starting at `# `).
- [ ] 8.3 New `scripts/translate-readme.sh` (`--all`, `--locale L` repeatable, `--dry-run`, `--switcher-only`): builds input, calls `${GRID_TRANSLATE_CMD:-claude -p --model sonnet --max-turns 1}`, validates (fence count, markers, relative links, starts at `# `), writes header + banner + body atomically to `README.<locale>.md`, rewrites the `<!-- langs -->` switcher in README.md and all existing translations, then runs `python3 scripts/stamp-counts.py`. Failure keeps old files, exits 1. `--dry-run` prints locales and estimated input size, calls nothing.
- [ ] 8.4 New `scripts/check-translations.sh [--strict]` per design.md; `scripts/gate.sh` runs it (non-strict) after bats and prints `WARN: stale translations: ...` without changing the gate result.
- [ ] 8.5 New `tests/test_readme_translations.bats` (temp `GRID_DIR` copy of README + scripts, stub `GRID_TRANSLATE_CMD` that echoes a fixed body): generates a file with correct header hash; switcher lists only existing files; editing prose in README makes `check-translations.sh` print `STALE` and exit 1; changing only a count marker value or the switcher block does not; a stub returning broken output (fence mismatch) leaves the old file and exits 1; `--strict` fails on a missing locale; `--dry-run` never invokes the stub; `--switcher-only` makes no stub call; a second `--all` run with an unchanged README is a byte-identical no-op for files whose hash matches (skip locales already current).
- [ ] 8.6 `CLAUDE.md` Key files: add `scripts/translate-readme.sh` and `scripts/check-translations.sh` with the regeneration instruction ("after README prose changes: `bash scripts/translate-readme.sh --all`; opt-in, costs tokens").
- Acceptance: new bats pass; gate prints no failure when no translations exist.
- Verify: `bash scripts/gate.sh`

## 9. Demo tape

Depends on: 4.

- [ ] 9.1 New `docs/demo/demo.tape` per design.md (comments at the top: how to record, `brew install vhs` / see vhs docs, run from repo root on a clean OS user with Claude logged in, why the clone is hidden).
- [ ] 9.2 New `tests/test_demo_tape.bats`: file has an `Output` line ending `.gif`, `Require git`, `Require claude`, a `bootstrap.sh --with-agents` line, a `/tron` line, no `/Users/` or `/home/`; sum of `Sleep` values <= 20 s; if `docs/demo/bootstrap-to-tron.gif` exists it is <= 3 MB.
- Acceptance: new bats pass.
- Verify: `bash scripts/gate.sh`

## 10. Repo metadata script

Depends on: nothing.

- [ ] 10.1 New `scripts/repo-metadata.sh [--check|--apply]` per design.md (constants for description, homepage, 10 topics; repo from `GRID_REPO` or parsed from `git remote get-url origin` supporting `git@host-alias:owner/repo.git` and https forms). `--check` default, read-only; `--apply` calls `gh repo edit` once for description+homepage and once per missing/extra topic. Fails clearly if `gh` is missing or unauthenticated.
- [ ] 10.2 New `tests/test_repo_metadata.bats` with a stub `gh` first on PATH: `--check` exits 0 when stub returns matching JSON; exits 1 and prints a diff when description or a topic differs; `--apply` calls the stub with the expected `repo edit` arguments (recorded to a temp log) and never runs in `--check`; remote parsing works for the alias and https forms.
- Acceptance: new bats pass; shellcheck clean.
- Verify: `bash scripts/gate.sh`

## 11. HUMAN: copy sign-off

Depends on: 4, 7. Blocks 13.

- [ ] 11.1 HUMAN: read README.md and index.html copy top to bottom in your own voice: hero sentence (does "every AI tool you use" sit right next to the Claude-Code-today line?), Who it's for, What you get, Status. Edit README.md; mirror edits into index.html; run `python3 scripts/stamp-counts.py` and `bash scripts/gate.sh` (the byte-identical hero/install test enforces parity).
- [ ] 11.2 HUMAN: time the quickstart on a clean machine (`time` the command with a fresh clone). If the README or site claims a duration, make it match; if > 2 min, state it ("first run fetches the upstream repos").
- [ ] 11.3 HUMAN: self-test #25 acceptance: someone (or a fresh OS user) wires a first skill from README alone and sees the "you should now see" outputs; note result on issue #25.
- [ ] 11.4 HUMAN: close #7 with a comment: the LAMP build prompt was retired (superseded by the role-by-role port in `agent-factory/roles/`; moved to the private archive by change `depersonalise`).
- Acceptance: gate green; #25 acceptance box checked; #7 closed.
- Verify: `bash scripts/gate.sh`

## 12. HUMAN: render demo, visual sign-off, social preview

Depends on: 7, 9, 11.

- [ ] 12.1 HUMAN: on a clean OS user with Claude Code logged in, run `vhs docs/demo/demo.tape` from the repo root; tune `Wait`/`Sleep` lines until the GIF is <= 20 s and <= 3 MB; add `docs/demo/bootstrap-to-tron.gif  # demo GIF, capped at 3 MB by tests/test_demo_tape.bats` to `scripts/personal-allow-paths.txt` (the size scan blocks files over 1 MB); commit tape tweaks, the allowlist line and the GIF.
- [ ] 12.2 HUMAN: add to README.md under Quickstart `![bootstrap to /tron](docs/demo/bootstrap-to-tron.gif)` with caption "Demo starts after the clone." and to index.html (`<img loading="lazy" width height alt>`); run gate.
- [ ] 12.3 HUMAN: review the site visually at 1280x800 and 390x844 (hero crop, contrast, Flynn band, install copy button, buttons, SVG diagram in dark and light OS themes); fix CSS nits.
- [ ] 12.4 HUMAN: upload `assets/og.jpg` at Settings -> Social preview (no API for this); share the link in a chat client and check the card renders.
- Acceptance: GIF committed and referenced from both pages; social card shows.
- Verify: `bash scripts/gate.sh`

## 13. HUMAN: generate translations

Depends on: 8, 11. Costs tokens (about 9 Sonnet calls); run once per README prose change.

- [ ] 13.1 HUMAN: `bash scripts/translate-readme.sh --all`; skim each file (code blocks, links, banner, quote intact; header hash present).
- [ ] 13.2 HUMAN: `bash scripts/check-translations.sh --strict` exits 0; `bash scripts/gate.sh` green; commit `README.<locale>.md` and the updated README switcher.
- Acceptance: nine `README.<locale>.md` exist, switcher in README.md lists all nine, strict check passes.
- Verify: `bash scripts/check-translations.sh --strict && bash scripts/gate.sh`

## 14. HUMAN: apply GitHub About, homepage, topics

Depends on: foundations#7 (Pages returns 200), 10. Changes live public state: review the diff first.

- [ ] 14.1 HUMAN: `bash scripts/repo-metadata.sh --check` and read the diff; then `bash scripts/repo-metadata.sh --apply` as the account that owns the repo.
- [ ] 14.2 HUMAN: Settings -> Code security: enable "Private vulnerability reporting" (SECURITY.md depends on it); leave Discussions off.
- [ ] 14.3 HUMAN: `bash scripts/repo-metadata.sh --check` exits 0; `curl -sI https://oneafrikan.github.io/the-grid/ | head -1` shows 200.
- Acceptance: About, homepage and 10 topics visible on the repo page.
- Verify: `bash scripts/repo-metadata.sh --check`

## 15. HUMAN: tag v0.1.0

Depends on: 11, 12, 13, 14 and `next` merged to `main`.

- [ ] 15.1 HUMAN: on `main`: `bash scripts/gate.sh`, `bash scripts/check-translations.sh --strict`, `bash scripts/repo-metadata.sh --check` all pass; CI green on `main`.
- [ ] 15.2 HUMAN: move `[Unreleased]` entries in CHANGELOG.md under `## [0.1.0] - <date>`; commit; `git tag -a v0.1.0 -m "v0.1.0"`; `git push origin v0.1.0`; `gh release create v0.1.0 --notes-from-tag`.
- Acceptance: release visible on GitHub; README Status wording matches ("Versioned from v0.1.0").
- Verify: `gh release view v0.1.0 --repo oneafrikan/the-grid`
