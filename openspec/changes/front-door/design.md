## Context

- Source review: landing-review.md (2026-10-09). Scorecard for the-grid: hook 2/1, proof 1, audience 1, About/SEO 1, CTAs 1.
- Facts checked against the repo today:
  - `README.md` is 410 lines; ~70% is maintainer material. The clone URL is `https://github.com/<your-username>/the-grid.git`.
  - `index.html` is 2000 lines, `<h1 class="hero-wordmark">` is visually hidden, the hero is `the-grid.png` (5.6 MB, 2816x1536), there are no links to the repo, only `<title>`, and counts are hand-typed (`137`, `~1,275`) and already disagree with `SKILLS.md` (library = 102).
  - `/tron` is an agent-factory orchestrator, so it is only wired by `bootstrap.sh --with-agents` (needs `python3`). The review's quickstart (plain bootstrap, then `/tron`) would fail. The quickstart below uses `--with-agents`.
  - `bootstrap.sh` ends with "Bootstrap complete. Open a fresh Claude session to pick up new skills/agents."
  - `catalog.sh` already prints total / wired / root-owned / upstream-wired / library in the committed `SKILLS.md` headline (`**239 skills indexed** — 137 wired live (14 root-owned + 123 from allowlisted repos), 102 in library ...`). Roles = 38 = `- role:` lines across `agent-factory/examples/*.yaml` (5+6+3+24).
  - `the-grid.png` stays in the repo after `depersonalise` (allowlisted in `scripts/personal-allow-paths.txt` until this change replaces it). `depersonalise` removes `prompts/2026-06-13-openclaw-lamp-team-prompt.md` to the private archive, which retires #7.
  - `depersonalise`'s size scan blocks tracked files over 1 MB unless allowlisted. Pages is served from `main` `/` with `.nojekyll` (`foundations`). `manifest-lock-install` adds `grid install` and documents it in BOOTSTRAP.md.
  - `gate.sh` runs shellcheck, catalog, compose, bats. CI runs only bats.
- Operator decisions (taken as fixed): the hero sentence, keep Tron reference + Flynn quote + ASCII art, "Who it's for" high, mermaid diagram, first-person author voice, README-only translations into 9 locales, no "why not ECC/gstack" section.
- Voice: first person ("I"), one byline "Gareth Knight" in the README footer and the site footer. `depersonalise` allows the name in prose docs; the author speaks as "I", never third person.

## Approach

Seven slices, in dependency order:

1. **Counts** become data: `scripts/stamp-counts.py` reads the committed `SKILLS.md` headline and rewrites marker comments in README*, index.html; `catalog.sh` restamps after regenerating; gate fails on drift. Everything after this uses markers instead of typed numbers.
2. **Doc split** lands before the README shrinks, so no content is lost: INSTALL, CONTRIBUTING, docs/architecture, docs/roadmap, docs/private-projects.
3. **README** rewritten against a fixed skeleton (below).
4. **Site assets** script + HUMAN render, then **index.html** rebuilt on those assets.
5. **Translations** pipeline (script, staleness check), generated only after HUMAN copy sign-off.
6. **Demo tape** + **repo-metadata script**, rendered/applied by HUMAN.
7. **Tag v0.1.0** by HUMAN last.

### README skeleton (target 150-180 lines, hard test bounds 140-185)

Order is fixed; the test asserts the `##` headings appear in this order.

| # | Block | Lines | Notes |
|---|---|---|---|
| 1 | `# the-grid`, hero sentence (bold, not a blockquote), badges, status one-liner, `<!-- langs -->` line | ~10 | |
| 2 | ASCII banner (code fence, from `the-grid.txt` content) | 9 | kept verbatim |
| 3 | `## Who it's for` | ~12 | 3 yes-bullets, 1 not-for bullet |
| 4 | `## Quickstart` | ~30 | clone+bootstrap, verify, paste-into-Claude variant |
| 5 | `## What you get` | ~14 | outcomes first, one count line via markers |
| 6 | `## How it works` | ~30 | mermaid + 4 bullets |
| 7 | `## Why "the grid"` | ~14 | Flynn monologue (9 lines) + attribution + 1 sentence on the name |
| 8 | `## Status` | ~12 | candid, kept from today's section |
| 9 | `## Docs` | ~12 | link list |
| 10 | `## Credits and license` | ~8 | wires-from line, MIT, byline |

Draft copy (implementer uses as written; HUMAN edits at sign-off):

- Hero (exact, verbatim, one paragraph, bold):
  `Inspired by Tron. Dotfiles for your AI assistant: curated skills and agent teams, wired identically onto every machine and every AI tool you use.`
- Status one-liner under badges: `Works today with Claude Code. Other AI tools: see [docs/roadmap.md](docs/roadmap.md).` (true whether or not `multi-harness` has shipped).
- Who it's for:
  - `You use more than one machine (laptop, server, work, home) and your Claude Code setup keeps drifting between them.`
  - `You collect skills from many repos and installing everything buries your session. You want a short live list and a searchable shelf.`
  - `You build agent teams (tech lead, QA, security reviewer) and want each role defined once and wired the same everywhere.`
  - `Not for you if you want a supported product, a GUI or a one-click installer. I built this for my own machines and share it because the mechanics are reusable.`
- What you get (outcomes, counts via markers):
  - `<!--count:wired-->N<!--/count--> curated skills as slash commands (/standup, /review, /ship, /skill-scout). <!--count:library-->N<!--/count--> more sit on a searchable shelf, switched off.`
  - `<!--count:roles-->N<!--/count--> ready-made agent roles: a dev team, a finance desk, a Socratic tutor (/morpheus), and /tron, which tells you which one to use.`
  - `One git pull plus wire.sh makes every machine identical; a per-machine overlay handles the differences.`
  - `Project templates with specs and agents already wired in.`
- Quickstart block (the exact command; also the install string on the site):

  ```bash
  git clone https://github.com/oneafrikan/the-grid.git ~/.the-grid && bash ~/.the-grid/scripts/bootstrap.sh --with-agents
  ```

  - Prerequisites line: `Needs git, bash, python3 (for the agent teams) and Claude Code. Node >= 20.19 only if you use the openspec-* skills (see INSTALL.md).`
  - "You should now see":
    - `bootstrap.sh` ends with `==> Bootstrap complete. Open a fresh Claude session to pick up new skills/agents.`
    - `ls ~/.claude/skills | wc -l` prints roughly `<!--count:wired-->N<!--/count-->` plus the orchestrator skills.
    - In a new Claude Code session `/tron` replies with a short question about what you want to do.
  - `Fork first if you plan to customise: the clone URL above is read-only for you.`
  - Paste-into-Claude variant (blockquote): `Clone https://github.com/oneafrikan/the-grid.git to ~/.the-grid, run bash ~/.the-grid/scripts/bootstrap.sh --with-agents, tell me what it printed, then tell me to open a fresh session and run /tron.`
  - Closing line: `Stop there. If it felt useful, read [USAGE.md](USAGE.md).`
- Credits line: `Wires skills from upstream projects, listed with licences in [docs/SOURCES.md](docs/SOURCES.md).` (no named "vs" comparison).
- Byline: `Built by [Gareth Knight](https://github.com/oneafrikan). MIT licensed.`

Mermaid (README `## How it works`, copied verbatim):

```mermaid
flowchart LR
  subgraph Sources
    R["repos/* submodules<br/>upstream skill repos"]
    S["skills/<br/>my own skills + edited forks"]
    A["agent-factory roles<br/>role x stack x skills"]
  end
  M["allowlist<br/>baseline + machines/HOST.txt"]
  C[compose.py]
  W[wire.sh]
  R --> M --> W
  S --> W
  A --> C --> W
  W -->|symlinks| K["~/.claude/skills<br/>~/.claude/agents"]
  R -. not on allowlist .-> L["Library<br/>SKILLS.md + /skill-scout"]
```

The four bullets under it: wired vs library; per-machine overlay; symlinks not copies (an edited root skill overrides the upstream copy); agents compiled from one source.

### Doc split map (README sections -> new home, content moved not rewritten)

| Today's README section | New home |
|---|---|
| Getting started (manual steps), openspec CLI note, Reconciling | `INSTALL.md` |
| Factories table, Repo layout, How wire.sh works | `docs/architecture.md` |
| Adding a skill, Adding a submodule, Running tests, Checking grid health | `CONTRIBUTING.md` |
| Private projects (with the overwrite warning) | `docs/private-projects.md` |
| Roadmap table + model routing note | `docs/roadmap.md` |
| Spec-driven development | 3-line pointer in README Docs, rest to `CONTRIBUTING.md` |
| Daily usage / help-skill table | already covered by USAGE.md; one row (`/tron`) stays in Quickstart |

`BOOTSTRAP.md` stays the full boot reference (it already has update, precedence, troubleshooting). `INSTALL.md` is the short outsider guide and links to it; no content is duplicated.

### Generated counts

No new data file. The source of truth is the committed `SKILLS.md` headline, which `catalog.sh` already writes and `catalog.sh --check` already guards.

- Keys (six): `indexed`, `wired`, `root_owned`, `upstream_wired`, `library` from the headline; `roles` = count of `^[[:space:]]*- role:` lines in `agent-factory/examples/*.yaml`.
- Headline regex (Python): `^\*\*(\d+) skills indexed\*\* — (\d+) wired live \((\d+) root-owned \+ (\d+) from allowlisted repos\), (\d+) in library` → indexed, wired, root_owned, upstream_wired, library.
- Marker: `<!--count:NAME-->VALUE<!--/count-->`, valid inline in Markdown and HTML. `NAME` must be one of the six keys.
- `scripts/stamp-counts.py` (python3 stdlib, honours `GRID_DIR`): rewrites VALUE in `README.md`, `README.*.md`, `index.html`; `--check` exits 1 and names the file on drift; exits 2 on an unknown NAME, or on a missing/unparsable headline when any marker exists; exits 0 when no file has markers. Idempotent.
- `catalog.sh` runs `stamp-counts.py` after writing the default `SKILLS.md` (not in `--check`, not with an output-path argument), so `wire.sh` keeps the counts current with no extra step.
- `gate.sh` gains a `counts` check (`python3 scripts/stamp-counts.py --check`), machine-independent because it compares committed files.

### index.html contract

- Keep one self-contained file (inline CSS, no web fonts, no CDN). New files: `assets/hero.webp`, `assets/og.jpg`, `assets/favicon.svg`.
- Head:
  - `<title>the-grid: dotfiles for your AI assistant</title>`
  - `<meta name="description" content="Dotfiles for your AI assistant: curated skills and agent teams, wired identically onto every machine. Free, MIT, Claude Code today.">` (<= 160 chars)
  - `<link rel="canonical" href="https://oneafrikan.github.io/the-grid/">`
  - `<link rel="icon" type="image/svg+xml" href="assets/favicon.svg">`, `<meta name="theme-color" content="#0d0d0f">`
  - Open Graph: `og:type=website`, `og:site_name`, `og:title`, `og:description`, `og:url`, `og:image` (absolute URL to `assets/og.jpg`), `og:image:width=1200`, `og:image:height=630`, `og:image:alt`.
  - Twitter: `twitter:card=summary_large_image`, `twitter:title`, `twitter:description`, `twitter:image`, `twitter:image:alt`.
  - JSON-LD `SoftwareSourceCode`:

    ```json
    {
      "@context": "https://schema.org",
      "@type": "SoftwareSourceCode",
      "name": "the-grid",
      "description": "Dotfiles for your AI assistant: curated skills and agent teams, wired identically onto every machine.",
      "codeRepository": "https://github.com/oneafrikan/the-grid",
      "url": "https://oneafrikan.github.io/the-grid/",
      "license": "https://opensource.org/licenses/MIT",
      "programmingLanguage": ["Shell", "Python"],
      "author": { "@type": "Person", "name": "Gareth Knight", "url": "https://github.com/oneafrikan" }
    }
    ```
- Body order: hero -> Who it's for -> Quickstart -> Flynn pull-quote band -> What you get -> How it works (inline SVG mirroring the mermaid nodes) -> Agents -> Skills summary -> Specs -> Roadmap -> Status -> Footer.
- Hero: `<picture>` with `assets/hero.webp` (1600x873, `fetchpriority="high"`, explicit width/height, `alt="the-grid"`), about 60vh. Over/below it, a visible `<h1>` containing the hero sentence verbatim, then `<pre><code id="install-cmd">` with the quickstart command, a Copy button (inline JS using `navigator.clipboard`, inside try/catch; button is `hidden` until JS runs), and two links styled as buttons: "View on GitHub" and "Star on GitHub" (both `https://github.com/oneafrikan/the-grid`), plus "Quickstart" anchor.
- Removed: "Key files", "Common commands", the per-repo Skills listing (replaced by one paragraph with markers and a link to SKILLS.md; it was a hand-synced copy of a generated file). The Agents cards, factories, Specs, Roadmap, Status sections are kept; typed numbers become markers.
- Fixed drift: Status bullet "partly personal ... open work, not done" replaced by README wording (personal config is gitignored). Footer: `Built by Gareth Knight. MIT. GitHub. Issues.` with links.
- Copy source of truth is README; the test asserts the hero sentence and install command are byte-identical in README, index.html (H1 and `#install-cmd`).

### Assets script

`scripts/build-site-assets.sh <source.png> [outdir=assets]` needs ImageMagick (`magick`, or `convert` on v6) with WebP support (`brew install imagemagick`, `apt install imagemagick`, `pacman -S imagemagick`); exits 3 with that message if absent. Outputs:

- `hero.webp`: resize to 1600 wide, `-quality 80 -define webp:method=6`; step quality down by 5 until < 300 KB (floor 50), exit 4 if still too large.
- `og.jpg`: 1200x630 cover-crop, centre gravity, `-quality 82`, strip metadata, must be < 250 KB.
- `favicon.svg` is not generated; it is a committed hand-written SVG (a simple grid glyph in the page accent colour).
- Strips metadata; output is deterministic for a given source and ImageMagick version.

### Translations

- Locales (file `scripts/lib/readme-locales.txt`, tab-separated, order = switcher order): `zh-CN 简体中文`, `ja 日本語`, `es Español`, `pt-BR Português (Brasil)`, `de Deutsch`, `fr Français`, `it Italiano`, `ko 한국어`, `ru Русский`.
- Files: `README.<locale>.md` at the repo root.
- Header of each translation (written by the script, not the model):

  ```
  <!-- machine-translated from README.md; source-sha256=<64 hex>; locale=ja; do not edit by hand -->
  <!-- langs -->[English](README.md) · **日本語** · [简体中文](README.zh-CN.md) ...<!-- /langs -->

  > Machine-translated from the [English README](README.md). The English version is authoritative.
  ```
- Switcher line lives between `<!-- langs -->` and `<!-- /langs -->` in README.md and every translation; lists only locales whose file exists; the current language is bold; `translate-readme.sh --switcher-only` rewrites all of them deterministically with no model call.
- Source hash = sha256 of README.md after (a) removing the `<!-- langs -->...<!-- /langs -->` block and (b) replacing every count-marker value with nothing (`<!--count:wired--><!--/count-->`). So adding a skill (count change) or adding a locale never marks translations stale; only prose edits do. Hash helper: `scripts/lib/readme-hash.sh` (uses `shasum -a 256` or `sha256sum`, whichever exists).
- Generation: `scripts/translate-readme.sh [--all | --locale L ...] [--dry-run]`. One model call per locale via `${GRID_TRANSLATE_CMD:-claude -p --model sonnet --max-turns 1}` with the prompt from `docs/translation-prompt.md` plus the normalised English README on stdin; tests set `GRID_TRANSLATE_CMD` to a stub. Estimated cost for all 9: roughly 30-40k input and 40-50k output tokens, once per README change; therefore opt-in only, never in gate or hooks.
- Output validation before writing (atomic: temp file then `mv`; on failure keep the old file, exit 1): same number of ``` fences as the source; every `<!--count:` marker preserved; every relative link target in the source appears in the output; no leading chatter before the first `# `.
- Translation rules (in `docs/translation-prompt.md`): translate prose only; leave code blocks, commands, file paths, slash commands, identifiers, mermaid labels, the ASCII banner and the Flynn quote (English, with attribution) untouched; keep link targets; keep the `README.md` first-person voice; do not add or remove sections.
- `scripts/check-translations.sh [--strict]`: for each locale file that exists, compare `source-sha256` with the current hash; print `STALE <locale>` and exit 1 if any existing file is stale; `--strict` additionally exits 1 for a missing locale file. Missing files are otherwise ignored.
- Gate: runs `check-translations.sh` without `--strict`, prints a WARN list, never fails the gate.

### Demo tape

`docs/demo/demo.tape` (charmbracelet vhs). Records on a clean machine/OS user with Claude Code logged in (`claude` auth is per-user, so a throwaway `$HOME` cannot work). The clone happens in a `Hide` block (it takes minutes), then the visible part re-runs the idempotent bootstrap:

```
Output docs/demo/bootstrap-to-tron.gif
Require git
Require claude
Set Shell "bash"
Set FontSize 16
Set Width 1200
Set Height 675
Set TypingSpeed 40ms
Set Theme "Dracula"
Hide
Type "git clone https://github.com/oneafrikan/the-grid.git ~/.the-grid && bash ~/.the-grid/scripts/bootstrap.sh --with-agents > /dev/null && clear" Enter
Wait+Screen /\$ $/
Show
Type "bash ~/.the-grid/scripts/bootstrap.sh --with-agents" Enter
Wait /Bootstrap complete/
Sleep 1s
Type "ls ~/.claude/skills | wc -l" Enter
Sleep 2s
Type "claude" Enter
Sleep 4s
Type "/tron" Enter
Sleep 8s
```

(Exact `Wait` regex tuning is the human's during the render task; the committed tape must keep: Output .gif, both `Require`s, the `--with-agents` bootstrap line, `/tron`, no absolute user paths, and visible `Sleep` total <= 20 s.) The README caption says the demo starts after the clone.

### Repo metadata

`scripts/repo-metadata.sh [--check|--apply]` (default `--check`): reads desired values from constants at the top of the script, compares with `gh repo view --json description,homepageUrl,repositoryTopics`, prints a diff, exits 1 on drift. `--apply` runs `gh repo edit` (description, homepage, `--add-topic` for missing, `--remove-topic` for extras). Repo = `${GRID_REPO:-<owner/name parsed from git remote origin>}`. Tests put a stub `gh` first on PATH.

- Description: `Dotfiles for your AI assistant: curated skills and agent teams, wired identically onto every machine. Claude Code today, more AI tools next.`
- Homepage: `https://oneafrikan.github.io/the-grid/`
- Topics (10): `claude-code`, `claude-skills`, `agent-skills`, `ai-agents`, `dotfiles`, `subagents`, `skills-manager`, `openclaw`, `developer-tools`, `llm`.

## Decisions

- Decided: author voice is first person ("I") in README and site; one byline naming Gareth Knight in README footer and site footer; the name is already public in LICENSE.
- Decided: README is the copy source of truth; index.html mirrors it; a test enforces byte-identical hero sentence and install command.
- Decided: the quickstart command uses `--with-agents`, because `/tron` is an agent-factory orchestrator that plain bootstrap does not wire; this also fixes the review's broken step 1.
- Decided: the README makes no "60 seconds" or timing claim until a HUMAN times it on a clean machine; the first run fetches ~36 submodules and is probably slower.
- Decided: keep Tron elements as follows: ASCII banner directly under the hero block (it is the wordmark), Flynn monologue in its own `## Why "the grid"` section after How it works, not collapsed. On the site, the monologue becomes a pull-quote band after Quickstart. Reason: prominent, but after the message.
- Decided: no named-competitor section, no "vs" table, no ECC/gstack in hero or in any heading; the Credits line points at `docs/SOURCES.md` and names no project.
- Decided: add INSTALL.md as a short outsider guide and keep BOOTSTRAP.md as the full reference; reason: BOOTSTRAP already holds update/precedence/troubleshooting, so duplicating it into INSTALL would drift.
- Decided: nothing is deleted in the doc split; text moves verbatim and only paths/URLs are corrected, so reviewers can diff by section.
- Decided: counts come from the committed `SKILLS.md` headline, not a new `docs/stats.json`; reason: SKILLS.md is already generated, committed and drift-checked, so a second data file would only duplicate it. `stamp-counts.py` is Python stdlib (regex), not bash, because it edits HTML/Markdown in place across several files.
- Decided: if the SKILLS.md headline format changes, `stamp-counts.py` exits 2 and a test against the real SKILLS.md fails; the headline format is the contract.
- Decided: marker form `<!--count:NAME-->VALUE<!--/count-->`; reason: invisible in both Markdown and HTML renderers, greppable, safe to repeat.
- Decided: the hero image is a WebP under 300 KB; the OG image is a JPEG, because several social crawlers still reject WebP.
- Decided: one 1200x630 `assets/og.jpg` serves both og:image and the GitHub social preview upload; reason: GitHub accepts it and a second 1280x640 file is another asset to keep in sync.
- Decided: ImageMagick is the single image dependency for `build-site-assets.sh`; the real render is HUMAN on macOS, and the script's bats test skips when ImageMagick is absent.
- Decided: the HUMAN render reads `the-grid.png` from the repo, copies it to the private repo, and group 7 then `git rm`s it and drops its `personal-allow-paths.txt` line; the script takes the source path as an argument so later re-renders use the private copy.
- Decided: no GitHub star-button widget or third-party script; "Star on GitHub" is a plain link to the repo. Reason: no network requests, no tracking.
- Decided: the architecture diagram on the site is a hand-authored inline SVG with the same nodes as the mermaid source; reason: Pages cannot render mermaid without a CDN script. Both are listed in `docs/architecture.md` as needing joint edits.
- Decided: remove "Key files", "Common commands" and the per-repo Skills listing from index.html; reason: reference material belongs in README docs/CONTRIBUTING and SKILLS.md is the generated catalogue.
- Decided: translations are generated by script via one `claude -p --model sonnet` call per locale, opt-in, never from gate or hooks; reason: token cost is a design constraint.
- Decided: translation staleness is a gate WARN, never a gate FAIL; `--strict` is used only by the release task. Reason: an unattended loop must not be blocked by every README edit.
- Decided: staleness hash ignores the switcher block and count values; reason: skill counts change constantly and are stamped into translations by `stamp-counts.py`.
- Decided: the Flynn quote stays in English in every translation; reason: it is a quotation with attribution.
- Decided: the switcher lists only existing translation files, so there are never dead links before the HUMAN generation task runs.
- Decided: Discussions stay off; CONTRIBUTING says "issues only". Reason: no capacity to moderate a second channel.
- Decided: SECURITY.md reports through GitHub private vulnerability reporting (HUMAN enables it); no email address in the repo.
- Decided: SECURITY.md promises "best-effort acknowledgement within 7 days", no bounty, supported = latest tag and `main`.
- Decided: CONTRIBUTING.md says to branch from and open PRs against `next` (the integration branch) and that nothing reaches `main` unreviewed. Reason: matches the current workflow; revisit if `next` is retired.
- Decided: CHANGELOG.md is Keep-a-Changelog style with `## [Unreleased]` and a `## [0.1.0]` entry added in the tag task.
- Decided: topics applied now are the 10 listed; `codex`, `gemini-cli` and `opencode` are added by a later edit only after `multi-harness#10` (HUMAN smoke test) passes for that harness. Reason: topics are a claim about what the repo does; today only Claude Code works.
- Decided: the GitHub About text is the hero sentence minus "Inspired by Tron" plus an honest suffix ("Claude Code today, more AI tools next"); reason: About is shown standalone and must not overclaim.
- Decided: `scripts/repo-metadata.sh` is the only way metadata is applied, so the HUMAN task is one reviewed command and reproducible later.
- Decided: tag `v0.1.0` is annotated, created by HUMAN on `main` after `next` is merged, with `gh release create v0.1.0 --notes-from-tag`; README Status wording changes from "No versioning" to "Versioned from v0.1.0; v0.x may still break between tags".
- Decided: the LAMP build prompt (#7) is retired by `depersonalise` (moved to the private archive); this change only closes #7 with a comment in the HUMAN sign-off. Reason: the file is already gone when this change lands.
- Decided: demo recording is HUMAN (needs a real terminal and Claude auth); the tape lives in the repo so it is re-renderable; the GIF is referenced from README and index.html only after it exists, and must be <= 3 MB.
- Decided: demo tape hides the initial clone and shows the idempotent bootstrap re-run, with a README caption saying so; reason: the real clone takes minutes and would blow the 20 s budget.
- Decided: Pages serves the repo root with `.nojekyll` (`foundations`), so `assets/` is published with no config change.
- Decided: the demo GIF is added to `scripts/personal-allow-paths.txt` with a reason, because `depersonalise`'s size scan blocks files over 1 MB; its own 3 MB cap is enforced by `tests/test_demo_tape.bats`.
- Decided: the quickstart stays `bootstrap.sh --with-agents` even though `grid install` exists, because bootstrap is the path that composes the agent teams `/tron` needs; INSTALL.md links BOOTSTRAP.md's "Install without submodules" section for `grid install`.
- Decided: `index.html` total size stays under 100 KB and its page weight (HTML + hero.webp + favicon) under 450 KB; a bats test asserts the two file limits.
- Decided: stale "29 skills" style typed numbers anywhere in README*/index.html are bugs: the stamping test fails if a bare number sits next to the words skills/agents/roles outside a marker (regex `\b[0-9]{2,4}\s+(skills|agents|roles)\b` in README.md and index.html).
- Decided: nothing in this change edits USAGE.md or BOOTSTRAP.md other than fixing links that point to README sections that moved.

## Risks / open items

- The hero says "every AI tool you use"; the operator kept it verbatim with the "Works today with Claude Code" line directly under it.
- Group 7 (index.html) is blocked on a HUMAN asset render (group 6); the unattended loop skips it until the assets are committed.
- If the quickstart ever moves to `grid install`, the README, the tape and the install string on the site change together (the byte-identical test makes that one change).
