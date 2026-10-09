# Design: foundations

## Context

- `.github/workflows/tests.yml` checks out recursively and runs bare `bats`. No venv is built, so every `agent-factory` test skips (`skip "agent-factory venv not built"`).
- Three tests always fail on a runner:
  - `skills dir exists` (`tests/test_repo_health.bats`): there is no `~/.claude/skills` on a runner.
  - `every wired SKILL.md has a name field` and `... description field` (`tests/test_skill_format.bats`): `baseline-submodules.txt` is gitignored, so on a runner the test falls back to "wire everything" and scans library submodules (for example sample fixtures under `repos/alirezarezvani`).
- The same test file re-implements wire.sh discovery with a plain `find`, so it drifts from `wire.sh`.
- GitHub Pages (legacy build, source `main` `/`, build type `legacy`) fails every build. Read from the failing `pages-build-deployment` run log: the submodule fetch succeeds for all 36 repos (`actions/checkout` rewrites `git@github.com:` to HTTPS with `url.https://github.com/.insteadOf`), and the failure is in the Jekyll step: `Invalid YAML front matter in .../repos/jeffallan/site/src/components/SocialIcons.astro`, after about 20 other `YAML Exception reading .../repos/**/SKILL.md` lines. The repo has no `.nojekyll`, so Jekyll walks `repos/**`. The SSH URLs are not the cause of the Pages or CI failures (issue #37 is about fresh-machine bootstrap only).
- CI facts from the latest `main` run of `tests.yml` (read with `gh run view`): `actions/checkout@v4` with `submodules: recursive` and the default `fetch-depth: 1` clones all 36 submodules shallow in about 104 s of the 142 s job; bats takes about 30 s. The run reports 147 tests, 81 skipped with `agent-factory venv not built`, 3 failed. The job warns `Node.js 20 is deprecated ... actions/checkout@v4`. GitHub's own Pages workflow uses `actions/checkout@v7.0.1` (tag `v7` exists). There is no branch protection or ruleset on `main`, so renaming the job breaks no required check.
- `find_skill_mds` (tracked-only discovery) still reports translations and per-harness copies. ECC reports 1027 SKILL.md files; 293 are under `skills/`. The rest are 518 under `docs/<locale>/`, 123 under `pi/core`, 43 `.kiro`, 39 `.agents`, 11 `.cursor`. `repos/alirezarezvani` reports 418 under `.gemini`.
- gstack: `wire.sh` symlinks the selected gstack skills, but each calls `~/.claude/skills/gstack/bin/...` and `browse/dist/browse`. Neither exists unless gstack's `./setup` has run. `wire.sh` also tears down every symlink that targets the grid dir, which would delete the runtime-root link `./setup` creates.
- `baseline-submodules.example.txt` has 8 mattpocock entries that no longer resolve (upstream renamed or removed them): `diagnose`, `edit-article`, `request-refactor-plan`, `to-issues`, `to-prd`, `ubiquitous-language`, `write-a-skill`, `zoom-out`. Its gstack header says 29 skills but lists 42. The only existing guard checks gstack.
- gstack has no git tags and no GitHub releases. The pin (VERSION 1.79.0.0) is behind upstream head (VERSION 1.91.68.0 when this was written).
- `./setup` side effects on global state (read from `repos/gstack/setup`):
  - Timeline `Stop` hook in the Claude settings file: default ON, persisted off by `--no-timeline-stop-hook`.
  - Plan-tune `PreToolUse` and `PostToolUse` AskUserQuestion hooks: prompt on a TTY (default N); auto opt-in under Conductor; `--no-plan-tune-hooks` forces off.
  - `SessionStart` auto-update hook: only with `--team`; `--no-team` removes it and runs `prune-stale --all` (removes every gstack-owned hook entry except source `verify-gate`).
  - Flat skill dirs: creates real directories in the skills dir (one per gstack skill, `SKILL.md` symlinked) plus alias copies `_gstack-command` and `connect-chrome`. It also converts an existing symlink at a skill's name (which is what `wire.sh` leaves there) into a real dir ("Upgrade old directory symlinks to real directories"). When the install root is not the default `~/.claude/skills/gstack`, 1.91 serves `SKILL.md` from a per-install render under gstack's state dir, so the `SKILL.md` symlink target is not reliably inside `repos/gstack`. `wire.sh` treats real dirs as "not managed", so they shadow its symlinks.
  - Runtime-root link: links `~/.claude/skills/gstack` to the checkout (`pwd -P`), and leaves an existing link to another checkout alone.
  - Optional installs: Homebrew `coreutils` on macOS (`GSTACK_SKIP_COREUTILS=1` skips), a color-emoji font via `sudo -n` on Linux (`GSTACK_SKIP_FONTS=1` skips), Playwright Chromium (needed).

## Approach

1. **Discovery first.** Put the exclusion rule in `find_skill_mds` so `wire.sh`, `catalog.sh`, and the tests all see one answer.
2. **Make CI mean the gate.** CI builds the venv and runs `scripts/gate.sh`. Tests that need "the wired set" ask `wire.sh` for it instead of mirroring it.
3. **Pages and URLs.** HTTPS URLs; Pages deploys by GitHub Actions from an explicit file list (`site-files.txt`, group 9), with `.nojekyll` kept as a fallback for the legacy source. Verification happens after merge to `main` (HUMAN group 7).
4. **Runtime check.** A small declarative map read by `wire.sh` (warn and link only) and by a wrapper script that does the human-run setup safely.
5. **gstack pin.** Bump after discovery and before the runtime check, so the baseline-resolve test proves the bump dropped no entry and the runtime flag-guard test (group 5) runs against the pin that will ship. Measured 2026-10-09: all 42 gstack entries in the example baseline resolve at upstream head (VERSION 1.91.68.0), and every flag in the runtime row exists in that `setup`.
6. **wire.sh teardown fixes and dry home.** Two live bugs in `teardown_grid_links` and the `GRID_DRY_HOME` redirect (group 8) land before the runtime link, because the link depends on teardown being correct.

### Exclusion rule (`scripts/lib/find-skill-mds.sh`)

`find_skill_mds <repo>` keeps its output contract (`<repo>/<relative path>` per line, exactly as today). After listing (git branch or `find` fallback) it drops any path whose repo-relative path matches one of:

1. **Translations.** Relative path starts with `docs/`, `i18n/`, `translations/` or `locales/`, followed by a locale component matching `^[a-z]{2}([-_][A-Za-z]{2,4})?$` (matches `tr`, `es`, `ja-JP`, `zh-CN`, `zh-TW`, `ko-KR`).
2. **Harness copies.** First path component starts with `.` (`.kiro`, `.agents`, `.cursor`, `.gemini`, `.openclaw`, `.claude`, ...).
3. **Listed prefixes.** A line in `scripts/lib/skill-excludes.txt` whose first field equals the repo directory name and whose second field is a prefix of the relative path.

`scripts/lib/skill-excludes.txt` (tracked, framework data, not personal curation):

```
# repo | path-prefix (relative to the repo root, trailing slash)
ecc | pi/
```

Expected counts (measured on the current pins): `repos/ecc` 1027 to 293 (all under `skills/`), `repos/alirezarezvani` 763 to 345, `repos/openclaw` 113 to 73, `repos/paperclip` 37 to 22, `repos/openspec` 16 to 12 (its four `.agents/skills/` maintainer skills, including `release-openspec`), `repos/ponytail` 12 to 6 (the `.openclaw` duplicates; `skills/` copies remain), `repos/clawhub` 12 to 0 (all under `.agents/`, so it becomes a reference repo in `SKILLS.md`). Every other repo is unchanged.

### Example baseline fix (`baseline-submodules.example.txt`)

mattpocock entries, mapped from the upstream git history:

| Old entry | New entry | Upstream change |
|---|---|---|
| `mattpocock/diagnose` | `mattpocock/diagnosing-bugs` | renamed |
| `mattpocock/to-issues` | `mattpocock/to-tickets` | planning skills unified |
| `mattpocock/to-prd` | `mattpocock/to-spec` | planning skills unified |
| `mattpocock/write-a-skill` | `mattpocock/writing-for-agents` | renamed (via `writing-great-skills`) |
| `mattpocock/edit-article` | (line deleted) | removed |
| `mattpocock/request-refactor-plan` | (line deleted) | removed |
| `mattpocock/ubiquitous-language` | (line deleted) | removed |
| `mattpocock/zoom-out` | (line deleted) | removed |

Header counts: gstack `(29 skills)` to `(42 skills)`, mattpocock `(21 skills)` to `(17 skills)`. The `-openspec/release-openspec` line and the comment sentence explaining it are deleted, because the exclusion rule already drops `.agents/skills/`; the openspec comment says the maintainer skills are excluded by the dot-dir rule instead.

The test reads the example only (the personal baseline is gitignored):

- Every positive per-skill line `<repo>/<skill>` resolves: `<skill>` equals the basename of a dir from `find_skill_mds repos/<repo>`. Entries whose repo is uninitialised are reported to fd 3 and not failed.
- Every positive whole-repo line names an existing `repos/<repo>` dir.
- Subtraction lines (`-…`) and `project:` lines are not checked (a dead subtraction is a harmless no-op; projects can be private).
- Every section header `# --- <repo> … (N skills) ---` whose repo has per-skill lines has N equal to the number of `<repo>/` lines.

### CI (`.github/workflows/tests.yml`)

```yaml
name: tests
on:
  push:
    branches: [main, next]
  pull_request:
# Least privilege: the gate only reads the repo.
permissions:
  contents: read
# A newer push to the same ref supersedes a running gate.
concurrency:
  group: tests-${{ github.ref }}
  cancel-in-progress: true
jobs:
  gate:
    # Pinned image: ubuntu-latest moves to a new LTS without notice and the
    # loop treats this job as its truth signal.
    runs-on: ubuntu-24.04
    timeout-minutes: 15
    steps:
      - uses: actions/checkout@v7
        with:
          submodules: recursive
      - name: Build agent-factory venv
        run: |
          python3 -m venv agent-factory/.venv
          agent-factory/.venv/bin/pip install -r agent-factory/requirements.txt
      # gate.sh skips shellcheck silently-ish when it is missing; on CI that
      # must be a hard failure, so assert the tool first.
      - name: Require shellcheck
        run: shellcheck --version
      - name: Gate
        run: bash scripts/gate.sh
```

On a runner `gate.sh` skips the catalog check (no personal baseline) and runs shellcheck, compose lint, and bats. Runner python is the image's system `python3` (no `setup-python`): the only dependency is PyYAML, pinned in `requirements.txt`. No pip or submodule cache: the 104 s submodule clone is the cost, but an `actions/cache` of 36 working trees would be keyed on 36 SHAs and save little; sparse submodule init is rejected because the example-baseline resolve test needs every repo named in the baseline.

### Wired-set helper for tests

`wire.sh` gains one env var: `GRID_BASELINE` (default `$GRID_DIR/baseline-submodules.txt`). It replaces the path in the first `load_manifest` call only; the machine overlays still load from `$GRID_DIR/machines/`. The `--check` branch needs no change because the child inherits the variable from the environment. This is the single definition other changes reference as `foundations#2`. The shared test helper `tests/helpers/wired.bash` exposes `wired_skill_dirs`:

```bash
# Runs the real wire.sh into a throwaway home against the personal baseline if
# present, else the tracked example, and prints each wired skill dir (the link
# target, trailing slash stripped). Links to a repo root (the runtime-root link,
# for example skills/gstack -> repos/gstack) are not skills and are left out.
# GRID_HOST=__baseline__ is the shared sentinel: no machine overlay matches it.
wired_skill_dirs() {
  local base="$REPO_ROOT/baseline-submodules.txt" tmp t
  [ -f "$base" ] || base="$REPO_ROOT/baseline-submodules.example.txt"
  tmp="$(mktemp -d)"
  GRID_DIR="$REPO_ROOT" GRID_BASELINE="$base" GRID_HOST=__baseline__ \
    GRID_DRY_HOME="$tmp/home" bash "$REPO_ROOT/scripts/wire.sh" >/dev/null
  while IFS= read -r t; do
    t="${t%/}"
    [ "$(dirname "$t")" = "$REPO_ROOT/repos" ] && continue
    printf '%s\n' "$t"
  done < <(find "$tmp/home/.claude/skills" -maxdepth 1 -type l -exec readlink {} \;)
  rm -rf "$tmp"
}
```

This is the final form (task 8.5). Group 2 ships the same function with `GRID_SKIP_CATALOG=1 SKILLS_DIR="$tmp/skills" AGENTS_DIR="$tmp/agents"` in place of `GRID_DRY_HOME="$tmp/home"` and reads `$tmp/skills`, because `GRID_DRY_HOME` lands in group 8.

### Dry home (`GRID_DRY_HOME`, group 8)

`GRID_DRY_HOME=<dir>` makes a `wire.sh` run touch nothing outside `<dir>` (and nothing in the repo). Placed right after `GRID_DIR` is set, before any home-derived default:

```bash
# GRID_DRY_HOME: redirect EVERY home-derived target into a throwaway home.
# Values are forced, not defaulted, so an inherited SKILLS_DIR or
# CLAUDE_CONFIG_DIR from the operator's shell cannot leak a dry run into the
# real home. Later changes that add a home target (RULES_DIR,
# GRID_HARNESS_HOME, ~/.grid state) MUST force it under GRID_DRY_HOME here.
if [ -n "${GRID_DRY_HOME:-}" ]; then
  mkdir -p "$GRID_DRY_HOME"
  export HOME="$GRID_DRY_HOME"
  SKILLS_DIR="$GRID_DRY_HOME/.claude/skills"
  AGENTS_DIR="$GRID_DRY_HOME/.claude/agents"
  export CLAUDE_CONFIG_DIR="$GRID_DRY_HOME/.claude"
  export GRID_SKIP_CATALOG=1   # no SKILLS.md / .wired.manifest writes either
fi
```

Every dry-run caller in the uplift (this change's `--check` child and `wired_skill_dirs`; `vetting` `audit.sh --wired|--gate`; `budget-and-usage` `baseline_wired.py`; `manifest-lock-install` `grid lock`) sets `GRID_DRY_HOME` and reads `$GRID_DRY_HOME/.claude/skills` and `.../agents`. Other changes reference this as `foundations#8`.

### Pages deploy (group 9)

`site-files.txt` (repo root, tracked) lists what is published, one repo-relative path per line (a directory is copied whole). Initial content: `index.html`, `the-grid.png` (the only local asset `index.html` references today). `front-door` appends its `assets/` entries. `scripts/stage-site.sh <out-dir>` copies exactly those paths into a fresh `<out-dir>`; it rejects absolute paths, `..`, and anything under `repos/`, `.git` or `.github` (exit 2), and fails on a missing path (exit 1).

```yaml
name: pages
on:
  push:
    branches: [main]
  workflow_dispatch:
# Pages deploy needs pages:write and an OIDC token; nothing else.
permissions:
  contents: read
  pages: write
  id-token: write
# One deploy at a time; never cancel a deploy in flight.
concurrency:
  group: pages
  cancel-in-progress: false
jobs:
  deploy:
    runs-on: ubuntu-24.04
    timeout-minutes: 10
    environment:
      name: github-pages
      url: ${{ steps.deployment.outputs.page_url }}
    steps:
      # No submodules: the site is index.html plus listed assets only.
      - uses: actions/checkout@v7
      - name: Stage site files
        run: bash scripts/stage-site.sh _site
      - uses: actions/configure-pages@v6
      - uses: actions/upload-pages-artifact@v5
        with:
          path: _site
      - id: deployment
        uses: actions/deploy-pages@v5
```

Action majors checked 2026-10-09 with `gh api repos/actions/<name>/git/ref/tags/<tag>`: `checkout@v7`, `configure-pages@v6`, `upload-pages-artifact@v5`, `deploy-pages@v5` all exist.
### Runtime map (`scripts/lib/runtimes.txt`)

Pipe-separated, `#` comments, one row per submodule that needs more than files on disk:

```
# repo | link | marker | needs | setup
gstack | gstack | browse/dist/browse | bun | GSTACK_SKIP_COREUTILS=${GSTACK_SKIP_COREUTILS:-1} GSTACK_SKIP_FONTS=${GSTACK_SKIP_FONTS:-1} ./setup --host claude --no-prefix --no-team --no-plan-tune-hooks --no-timeline-stop-hook -q
```

- `repo`: directory name under `repos/`.
- `link`: name of the symlink `wire.sh` keeps in the skills dir, pointing at `repos/<repo>` (the runtime root skills reference as `~/.claude/skills/<link>/...`). Empty means no link.
- `marker`: path relative to `repos/<repo>` that must exist and be executable (or a non-empty file when not executable).
- `needs`: command that must be on `PATH` to run `setup`.
- `setup`: command run with `bash -c` inside `repos/<repo>`.

`wire.sh` reads the map from `$GRID_DIR/scripts/lib/runtimes.txt` (absent file means nothing to do, so mock-grid tests are unaffected). For each row whose repo is active (whole-repo entry or any per-skill entry, and not denied):

- Ensure `$SKILLS_DIR/<link>` is a symlink to `$GRID_DIR/repos/<repo>` (exact shape: absolute target, no trailing slash, made with `ln -sfn "$GRID_DIR/repos/<repo>" "$SKILLS_DIR/<link>"`; for gstack, `$SKILLS_DIR/gstack -> $GRID_DIR/repos/gstack`), after the repo's skills are wired so the link wins a name clash. A real dir at that path, or a symlink to anywhere else (for example an earlier standalone gstack install), is skipped with a `skip (runtime root occupied, not managed): <link>` line and a manifest row with status `skipped`. gstack's own `setup` also refuses to repoint a link that targets another still-present checkout, so the-grid must not either.
- If the marker is missing, print `  runtime MISSING: <repo> (<marker>) - run: bash scripts/runtime-setup.sh <repo>` and add a manifest row with status `missing`. Exit status stays 0.

`wire.sh --check` needs no change: the link is a grid-owned symlink and is compared like the others.

### `scripts/runtime-setup.sh <repo>`

1. Look up the row; unknown repo, uninitialised submodule, or missing `needs` command is a non-zero exit with a message (2). Also exit 2 if `$SKILLS_DIR/<link>` exists and is not a symlink to `$GRID_DIR/repos/<repo>` (message: remove or move it first; the-grid never deletes it), because setup would leave it alone and skip registration while `wire.sh` kept warning.
2. Copy `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json` to a temp file (or note it is absent).
3. Run the `setup` field with `bash -c` inside `repos/<repo>`.
4. Compare with `cmp -s` (absent before and after counts as equal). If it differs, print a `diff` of the two and the gstack rollback command (`repos/gstack/bin/gstack-settings-hook rollback`) and exit 3. The change is not reverted by the script. (`cmp` and `diff` are in POSIX; `sha256sum` vs `shasum` differs between macOS and Linux.)
5. Remove setup's flat skill dirs. Before step 3 the wrapper records the names of real (non-symlink) directories directly under the skills dir; after step 3 it removes every real directory directly under the skills dir that was not in that list and whose name is a skill dir name in `find_skill_mds repos/<repo>`. This catches both new dirs and wired symlinks setup converted to real dirs, whatever their `SKILL.md` points at. Pre-existing real dirs and alias copies (`_gstack-command`, `connect-chrome`, `gstack-connect-chrome`: not skill dir names) are never removed; alias copies created by this run are listed.
6. Run `wire.sh` (re-creates the wired symlinks and the runtime link). Then print `git -C repos/<repo> status --short` if non-empty under a `WARNING: setup modified tracked files in the submodule` heading (setup's `gstack-patch-names` rewrites `name:` lines in tracked `SKILL.md` files in some prefix states); report only, never revert or commit.
7. Re-running is a no-op: setup rebuilds nothing, step 5 finds no real dirs, `wire.sh` is idempotent.

### Hook-free setup: the exact flags

| Flag | Effect | Why |
|---|---|---|
| `--no-team` | No `SessionStart` auto-update hook; also prunes any existing gstack-owned hook entries from the global settings file (keeps source `verify-gate`) | Strips hooks left by an earlier install |
| `--no-plan-tune-hooks` | No AskUserQuestion `PreToolUse` and `PostToolUse` hooks; beats the TTY prompt and the Conductor auto opt-in | Otherwise an interactive run prompts and a Conductor run installs |
| `--no-timeline-stop-hook` | No `Stop` hook; persists `timeline_stop_hook: no` in gstack config so later bare `./setup` (run by `/gstack-upgrade`) stays off | Default is ON |
| `--no-prefix` | Short names (`/review`), persisted as `skill_prefix: false` | Matches the names `wire.sh` links |
| `-q` | No interactive prompts (including the pre-push credential-guard prompt) | Unattended safe |
| `--host claude` | Claude only; no Codex, Kiro, Cursor installs | Explicit beats `auto` |

Residual: every `./setup` run first heals gstack-owned hook entries (`prune-stale --repoint`); it never adds one, and it is a no-op on a clean settings file. The wrapper's hash check proves it.

### wire.sh teardown fixes (group 8)

Both are in `teardown_grid_links` (`scripts/wire.sh`, currently around line 172); the same two changes apply to `--check`'s `links()` helper where relevant.

- Prefix match: `[[ "$target" == "$GRID_DIR"* ]]` also matches a sibling directory that merely shares the prefix (`${GRID_DIR}-private`, `${GRID_DIR}2`), so a foreign link into it is deleted. Change to `[[ "$target" == "$GRID_DIR"/* ]]`. `--check`'s `links()` already uses `"$GRID_DIR"/*`.
- Symlinked skills dir: `find "$dir" -maxdepth 1 -type l` lists nothing when `$dir` is itself a symlink, so teardown silently removes nothing and stale links survive. Use `find -H "$dir" ...` (`-H` follows only the command-line argument; supported by BSD and GNU find) in `teardown_grid_links` and in `links()` in `--check`.

## Decisions


- Decided: exclusion lives inside `find_skill_mds`, not in `wire.sh` and `catalog.sh` separately, because both already source it and a single rule cannot drift.
- Decided: any root-level dot-dir is excluded, because what lives there is either a per-harness copy (ECC, alirezarezvani, ponytail) or the upstream repo's own maintainer skills (openspec, openclaw, paperclip, clawhub), and of those only openspec is wired; a blanket rule is simpler than a harness-name list that goes stale. `repos/clawhub` becoming a reference repo is accepted.
- Decided: translation dirs are matched by the 2-letter locale regex, not by a fixed list, because ECC alone has six locales and more will come; known limit: a real `docs/ui/` skill dir would be excluded, so add an explicit prefix rule only if that ever happens.
- Decided: `pi/` for ECC is a listed prefix, not a generic rule, because `pi` is not a dot-dir and appears in no other repo.
- Decided: `skill-excludes.txt` is read from `scripts/lib/` next to `find-skill-mds.sh` (not from `GRID_DIR`), because mock-grid tests use the real script and repo names that do not match any row.
- Decided: the openspec maintainer skills under `.agents/skills/` stop being wired, because the baseline comment says 12 workflow skills and already subtracts `release-openspec` as maintainer-only; the now-dead `-openspec/release-openspec` line is deleted from the example baseline.
- Decided: `SKILLS.md` is regenerated only on a machine that has a personal `baseline-submodules.txt`; an agent without one leaves it and says so in the PR body, because the catalogue is built from the personal baseline and a wrong baseline would commit wrong output.
- Decided: CI triggers on pushes to `main` and `next` and on every pull request, because loop-built PRs target `next` and must be gated.
- Decided: CI runs `bash scripts/gate.sh`, not bare bats, so CI and the loop's verify step are the same command.
- Decided: keep `submodules: recursive` in CI, because `tests/lib/bats-core` and the example-baseline tests need the submodules; `actions/checkout` clones them shallow, which is the cheap form.
- Decided: `skills dir exists` skips when `CI=true`, and still fails on a real machine, because it is a machine-health check and a skipped test on a runner is honest where a forced pass is not.
- Decided: add a CI-only guard test `agent-factory venv exists when CI=true`, so a regression of the workflow fails instead of silently skipping 81 tests again.
- Decided: tests obtain the wired set by running the real `wire.sh` into a temp dir with `GRID_BASELINE`, falling back to `baseline-submodules.example.txt` when the personal baseline is absent, because that removes the duplicated discovery logic and also covers per-skill entries, which the old test never scanned.
- Decided: `GRID_BASELINE` is the only new `wire.sh` input for tests; `catalog.sh` is not changed to read it.
- Decided: `.nojekyll` at the repo root stays (group 3.1), but it is no longer the Pages fix: it only keeps the legacy branch source building if the Actions switch is ever reverted. (Superseded by the Q9 decision below.)
- Decided: all 22 SSH submodule URLs convert to HTTPS after `gh repo view <owner>/<repo> --json isPrivate` confirms each is public; a private one stays SSH and is named in the PR body. `tests/test_submodule_sources.bats` has no allowlist; if one is ever needed, that change adds it.
- Decided: `docs/SOURCES.md` is regenerated with `bash scripts/sources.sh` when a personal baseline exists; otherwise the implementer deletes only the SSH marker (` ᵍ`) and its footnote line by hand and says so in the PR body.
- Decided: every machine runs `git submodule sync --recursive` once after pulling the URL change; this is stated in `BOOTSTRAP.md` and in the HUMAN task.
- Decided: gstack has no tags or releases, so "latest upstream tag" means the upstream default-branch head commit at implementation time. The implementer records its `VERSION` in the commit message and refuses to proceed if that VERSION is lower than `1.91`.
- Decided: a bats test fixes a version floor (`repos/gstack/VERSION` major.minor at least 1.91, skipped when the submodule is uninitialised) so the pin cannot silently regress.
- Decided: renamed mattpocock entries follow upstream and removed ones are deleted (table above); no replacement skill is added, because adding skills is curation, not a fix.
- Decided: the resolve test covers every positive per-skill entry in every repo of the example baseline, and the header-count test covers every section with per-skill entries; whole-repo header counts (openspec, ponytail) are not tested, because they move with every upstream bump and would fail the gate on comment drift.
- Decided: runtime handling is warn-only in `wire.sh` (exit 0), because wiring must stay safe on CI runners and on machines that deliberately skip the runtime.
- Decided: `wire.sh` owns the runtime-root link (`~/.claude/skills/gstack`), because its teardown deletes every symlink into the grid dir and would otherwise remove the link `./setup` makes on every run.
- Decided: the wrapper skips Homebrew `coreutils` and the Linux emoji font by default (`GSTACK_SKIP_COREUTILS=1`, `GSTACK_SKIP_FONTS=1`, overridable from the caller's environment), because the-grid scripts must not run `brew` or `sudo` implicitly; the cost is no `gtimeout` hang protection in `/codex` and `/autoplan`, and emoji tofu in `make-pdf` on Linux.
- Decided: the wrapper detects a global-settings change by comparing a before-copy with `cmp -s` and exits 3 without reverting; reverting is gstack's `rollback`, which keeps its own backup.
- Decided: the wrapper removes only real dirs that appeared during this setup run and carry a skill dir name of the repo (snapshot before, diff after), not dirs selected by `SKILL.md` target, because 1.91 may serve `SKILL.md` from a render dir outside the submodule; alias copies are listed, not deleted.
- Decided: `scripts/lib/runtimes.txt` format is pipe-separated text, not YAML, because `wire.sh` is bash and there is no YAML parser dependency.
- Decided: `runtime-setup.sh` reads the map from `$GRID_DIR/scripts/lib/runtimes.txt` (same file `wire.sh` reads) and re-wires with `bash "$(dirname "$0")/wire.sh"`, inheriting `GRID_DIR` and `SKILLS_DIR`, so a mock grid in tests needs only the map, not a copy of the scripts.
- Decided: `runtime-setup.sh` is a standalone script, not a `wire.sh` flag, because wiring must stay offline and fast while setup downloads Chromium.
- Decided: bun is a prerequisite checked by the wrapper (`needs`), never installed by the-grid; the message points at gstack's own checksum-verified install instructions printed by `./setup`.
- Decided: docs touched are `CLAUDE.md` (wire.sh contract, runtime map, exclusion rule) and `BOOTSTRAP.md` (submodule sync, runtime step); no new top-level doc.

- Decided: the CI job is renamed `gate`, pinned to `ubuntu-24.04` (not `ubuntu-latest`), uses `actions/checkout@v7` (the version GitHub's own Pages workflow runs; clears the Node 20 deprecation warning), has `permissions: contents: read`, a per-ref `concurrency` group that cancels superseded runs, and `timeout-minutes: 15`, because the loop treats this job as its only truth signal and an image or action drift must not change its meaning. No branch protection exists, so the job rename breaks nothing.
- Decided: the workflow asserts `shellcheck --version` before the gate, because `gate.sh` skips shellcheck when absent and a skipped lint on the one trusted runner would be a silent hole. If the runner's shellcheck (possibly older than the 0.11 on the dev machine) flags a script, the implementer fixes the script warning, never adds a `disable` directive for it and never drops the step.
- Decided: no `setup-python`, no pip cache, no submodule cache, because PyYAML is the only dependency, the image python3 builds the venv, and the measured submodule clone (about 104 s) cannot be cached usefully (see CI section). Revisit only if the job exceeds 6 minutes.
- Decided: the foundations CI group owns the single venv-build step in `tests.yml`. `workflow-upgrades` task 2.7 (its own venv step) must become "Depends on: foundations#2; edit no workflow lines", and its design notes about CI building the venv (and the `blocked` stop rule) are superseded by task 2.6 here (a test that cannot run on a runner gets an explicit `skip` with a reason).
- Decided: "a push to `next` triggers the workflow" is verified after merge (HUMAN group 7), not in group 2, because a feature-branch push does not match the `push` filter; the PR run proves the workflow itself.
- Decided: the local no-baseline proof is the CI run, not renaming the operator's personal `baseline-submodules.txt`, because an unattended agent must not move personal files and its worktree may already lack the file.
- Decided: `.nojekyll` addresses the confirmed legacy-build root cause (Jekyll parsing `repos/**` front matter); GitHub's docs say it bypasses Jekyll in the publishing folder, but the `actions/jekyll-build-pages` entrypoint has no `.nojekyll` check, so on the legacy source it is confirmed only post-merge. Not relied on once the source is GitHub Actions.
- Decided: Pages deploys by GitHub Actions (`.github/workflows/pages.yml`, group 9) from `site-files.txt` via `scripts/stage-site.sh` and `actions/upload-pages-artifact`, not from the repo root, because the legacy source would publish about 544 MB of third-party submodule trees (measured 2026-10-09, against the 1 GB limit) and fetch 36 submodules on every `main` push. The cost is one repo-setting change (Pages source = "GitHub Actions", HUMAN 7.2) and a file list that `front-door` must append to (single tracked file `site-files.txt`).
  Pending operator: Q9 — Pages via Actions deploy of index.html + assets only (default YES); NO reverts group 9 and 7.2 to the `.nojekyll`-only legacy source.
- Decided: SSH to HTTPS URL conversion (#37) is justified by fresh-machine bootstrap, not by CI or Pages: `actions/checkout` already rewrites SSH GitHub URLs, as the latest runs show.
- Decided: group 4 (gstack bump) runs before group 5 (runtime check), the reverse of the earlier draft, so the flag-guard test in group 5 checks the real shipped `setup`. The implementer picks the upstream head at implementation time (it moves daily); the 2026-10-09 measurement above is evidence the bump is safe, not a pinned commit.
- Decided: a real-repo bats test asserts every `--flag` token in a `runtimes.txt` setup command appears in `repos/<repo>/setup` (skipped when uninitialised), because setup flags are upstream's to rename and a renamed `--no-timeline-stop-hook` would silently re-enable a global hook.
- Decided: the wrapper compares the Claude settings file with a temp copy and `cmp -s`, not a hash, because `sha256sum` and `shasum` differ across macOS, Ubuntu and Arch while `cmp` and `diff` are POSIX. This replaces the earlier SHA-256 Decided line.
- Decided: when `$SKILLS_DIR/<link>` is occupied by a real dir or a symlink to another checkout, `wire.sh` skips it (manifest status `skipped`) and the wrapper exits 2 before running setup, because upstream setup would leave it alone and the operator must choose to remove an existing global install; the-grid never deletes it.
- Decided: the wrapper reports (does not revert) tracked-file modifications inside the submodule after setup, because `gstack-patch-names` can rewrite `name:` lines and a dirty submodule blocks `git submodule update`.
- Decided: `GRID_DRY_HOME` (G1) is owned by foundations group 8 (tasks 8.4 to 8.6): when set, `wire.sh` exports `HOME` to it and FORCES `SKILLS_DIR`, `AGENTS_DIR` and `CLAUDE_CONFIG_DIR` under it (inherited values ignored) and sets `GRID_SKIP_CATALOG=1`, because a defaulted override would let an operator's exported variable leak a dry run into the real home. `wire.sh --check` and `wired_skill_dirs` use it; later home targets (RULES_DIR, GRID_HARNESS_HOME, ~/.grid state) must be forced in the same block and add the sentinel test. Placed in group 8, not a new group, because group 8 already edits `wire.sh` and every later group that wires depends on it.
- Decided: the sentinel host for baseline-only runs is `GRID_HOST=__baseline__` (G5), replacing the draft's `baseline-only`.
- Decided: the runtime-root link shape others depend on (G6) is `$SKILLS_DIR/<link> -> $GRID_DIR/repos/<repo>`, absolute, no trailing slash; for gstack `$SKILLS_DIR/gstack -> $GRID_DIR/repos/gstack`. It is not a skill: consumers detect it as a link whose target's parent is `$GRID_DIR/repos` (as `wired_skill_dirs` does).
- Decided: the example-baseline resolve test ignores typed lines (text before the first `/` contains `:`: `project:`, `rules:`, `harness:`, `hook:`, and their `-` forms) as well as subtractions (G4), so later typed manifest entries never fail it.
- Decided: the ECC count is checked as derived, not literal (QA15): `find_skill_mds repos/ecc | wc -l` must equal `git -C repos/ecc ls-files -- 'skills/*SKILL.md' | wc -l` (> 0), and in HUMAN 7.5 the `SKILLS.md` ECC section count must equal the `find_skill_mds` count; 293 is only the 2026-10-09 measurement.
- Decided: an existing standalone `~/.claude/skills/gstack` (not a link to `repos/gstack`) is removed by the operator before HUMAN group 6 (task 6.2); the-grid scripts still never delete it.
  Pending operator: Q10 — remove the standalone ~/.claude/skills/gstack before group 6 (default YES).
- Decided: wire.sh teardown fixes (sibling-prefix match, `find -H` for a symlinked skills dir) live in foundations group 8, because both are live bugs in the file this change already edits and `multi-harness` task 1.5(c) will depend on `foundations#8` instead of fixing them. Tests: a link into `${GRID_DIR}-private/x` survives a wire; with `SKILLS_DIR` a symlink to a real dir holding a stale grid link, the stale link is removed.

## Risks

- Venv tests have never run on a runner; a few may fail for environment reasons. Group 2 owns fixing them; a test that cannot run on a runner gets an explicit `skip` with a reason, never a deletion.
- `SKILLS.md` drifts until regenerated on a baseline machine (HUMAN group).
- Until the operator switches the Pages source (HUMAN 7.2), the `pages` workflow's deploy step fails on `main` and the legacy build (with `.nojekyll`) keeps serving; the switch is reversible.
- A new site asset not added to `site-files.txt` is not published; test 9.4(f) catches local references from `index.html` only.
- `./setup` writes persisted settings outside `~/.claude` (gstack's own config, for example `skill_prefix` and `timeline_stop_hook`, and the Playwright browser cache). The settings-file check does not cover them; HUMAN group 6 lists them.
- Runner shellcheck is older than the dev machines'; the first CI run may flag warnings the local gate does not.
