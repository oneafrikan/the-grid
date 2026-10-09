# Design: foundations

## Context

- `.github/workflows/tests.yml` checks out recursively and runs bare `bats`. No venv is built, so every `agent-factory` test skips (`skip "agent-factory venv not built"`).
- Three tests always fail on a runner:
  - `skills dir exists` (`tests/test_repo_health.bats`): there is no `~/.claude/skills` on a runner.
  - `every wired SKILL.md has a name field` and `... description field` (`tests/test_skill_format.bats`): `baseline-submodules.txt` is gitignored, so on a runner the test falls back to "wire everything" and scans library submodules (for example sample fixtures under `repos/alirezarezvani`).
- The same test file re-implements wire.sh discovery with a plain `find`, so it drifts from `wire.sh`.
- GitHub Pages (legacy build, source `main` `/`) fails every build. The repo has no `.nojekyll`, Jekyll walks `repos/**`, and 22 submodules use SSH URLs.
- `find_skill_mds` (tracked-only discovery) still reports translations and per-harness copies. ECC reports 1027 SKILL.md files; 293 are under `skills/`. The rest are 518 under `docs/<locale>/`, 123 under `pi/core`, 43 `.kiro`, 39 `.agents`, 11 `.cursor`. `repos/alirezarezvani` reports 418 under `.gemini`.
- gstack: `wire.sh` symlinks the selected gstack skills, but each calls `~/.claude/skills/gstack/bin/...` and `browse/dist/browse`. Neither exists unless gstack's `./setup` has run. `wire.sh` also tears down every symlink that targets the grid dir, which would delete the runtime-root link `./setup` creates.
- gstack has no git tags and no GitHub releases. The pin (VERSION 1.79.0.0) is behind upstream head (VERSION 1.91.68.0 when this was written).
- `./setup` side effects on global state (read from `repos/gstack/setup`):
  - Timeline `Stop` hook in the Claude settings file: default ON, persisted off by `--no-timeline-stop-hook`.
  - Plan-tune `PreToolUse` and `PostToolUse` AskUserQuestion hooks: prompt on a TTY (default N); auto opt-in under Conductor; `--no-plan-tune-hooks` forces off.
  - `SessionStart` auto-update hook: only with `--team`; `--no-team` removes it and runs `prune-stale --all` (removes every gstack-owned hook entry except source `verify-gate`).
  - Flat skill dirs: creates real directories in the skills dir (one per gstack skill, `SKILL.md` symlinked) plus alias copies `_gstack-command` and `connect-chrome`. `wire.sh` treats real dirs as "not managed", so they shadow its symlinks.
  - Optional installs: Homebrew `coreutils` on macOS (`GSTACK_SKIP_COREUTILS=1` skips), a color-emoji font via `sudo -n` on Linux (`GSTACK_SKIP_FONTS=1` skips), Playwright Chromium (needed).

## Approach

1. **Discovery first.** Put the exclusion rule in `find_skill_mds` so `wire.sh`, `catalog.sh`, and the tests all see one answer.
2. **Make CI mean the gate.** CI builds the venv and runs `scripts/gate.sh`. Tests that need "the wired set" ask `wire.sh` for it instead of mirroring it.
3. **Pages and URLs.** `.nojekyll` plus HTTPS URLs. Verification happens after merge to `main`.
4. **Runtime check.** A small declarative map read by `wire.sh` (warn and link only) and by a wrapper script that does the human-run setup safely.
5. **gstack pin.** Bump after discovery and runtime work, so tests prove the bump did not drop a baseline entry.

### Exclusion rule (`scripts/lib/find-skill-mds.sh`)

`find_skill_mds <repo>` keeps its output contract (absolute SKILL.md paths). After listing (git branch or `find` fallback) it drops any path whose repo-relative path matches one of:

1. **Translations.** Relative path starts with `docs/`, `i18n/`, `translations/` or `locales/`, followed by a locale component matching `^[a-z]{2}([-_][A-Za-z]{2,4})?$` (matches `tr`, `es`, `ja-JP`, `zh-CN`, `zh-TW`, `ko-KR`).
2. **Harness copies.** First path component starts with `.` (`.kiro`, `.agents`, `.cursor`, `.gemini`, `.openclaw`, `.claude`, ...).
3. **Listed prefixes.** A line in `scripts/lib/skill-excludes.txt` whose first field equals the repo directory name and whose second field is a prefix of the relative path.

`scripts/lib/skill-excludes.txt` (tracked, framework data, not personal curation):

```
# repo | path-prefix (relative to the repo root, trailing slash)
ecc | pi/
```

Expected result: `repos/ecc` yields 293, `repos/alirezarezvani` drops 418, `repos/openspec` loses its three maintainer skills under `.agents/skills/` (the baseline already subtracts the fourth, `release-openspec`; that subtraction stays), `repos/ponytail` drops its six `.openclaw` duplicates (the `skills/` copies remain).

### CI (`.github/workflows/tests.yml`)

```yaml
name: tests
on:
  push:
    branches: [main, next]
  pull_request:
jobs:
  gate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          submodules: recursive
      - name: Build agent-factory venv
        run: |
          python3 -m venv agent-factory/.venv
          agent-factory/.venv/bin/pip install -r agent-factory/requirements.txt
      - name: Gate
        run: bash scripts/gate.sh
```

On a runner `gate.sh` skips the catalog check (no personal baseline) and runs shellcheck, compose lint, and bats.

### Wired-set helper for tests

`wire.sh` gains one env var: `GRID_BASELINE` (default `$GRID_DIR/baseline-submodules.txt`). The shared test helper `tests/helpers/wired.bash` exposes `wired_skill_dirs`:

```bash
# Runs the real wire.sh into a throwaway dir against the personal baseline if
# present, else the tracked example, and prints each wired skill dir (resolved).
wired_skill_dirs() {
  local base="$REPO_ROOT/baseline-submodules.txt"
  [ -f "$base" ] || base="$REPO_ROOT/baseline-submodules.example.txt"
  local tmp; tmp="$(mktemp -d)"
  GRID_BASELINE="$base" GRID_HOST=baseline-only GRID_SKIP_CATALOG=1 \
    SKILLS_DIR="$tmp/skills" AGENTS_DIR="$tmp/agents" bash "$REPO_ROOT/scripts/wire.sh" >/dev/null
  find "$tmp/skills" -maxdepth 1 -type l -exec readlink {} \;
  rm -rf "$tmp"
}
```

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

- Ensure `$SKILLS_DIR/<link>` is a symlink to `$GRID_DIR/repos/<repo>`, after the repo's skills are wired so the link wins a name clash. A real dir at that path is skipped with the same "real dir, not managed" message and manifest row.
- If the marker is missing, print `  runtime MISSING: <repo> (<marker>) - run: bash scripts/runtime-setup.sh <repo>` and add a manifest row with status `missing`. Exit status stays 0.

`wire.sh --check` needs no change: the link is a grid-owned symlink and is compared like the others.

### `scripts/runtime-setup.sh <repo>`

1. Look up the row; unknown repo, uninitialised submodule, or missing `needs` command is a non-zero exit with a message (2).
2. Hash `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json` (or `absent`).
3. Run the `setup` field with `bash -c` inside `repos/<repo>`.
4. Re-hash. If it changed, print what changed and the gstack rollback command (`repos/gstack/bin/gstack-settings-hook rollback`) and exit 3. The change is not reverted by the script.
5. Remove setup's flat skill dirs: real directories directly under the skills dir whose `SKILL.md` is a symlink into `repos/<repo>/`. Never remove anything that resolves outside the skills dir. Alias copies (`_gstack-command`, `connect-chrome`) are left in place and listed.
6. Run `wire.sh` (re-creates the wired symlinks and the runtime link).
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

## Decisions

- Decided: exclusion lives inside `find_skill_mds`, not in `wire.sh` and `catalog.sh` separately, because both already source it and a single rule cannot drift.
- Decided: any root-level dot-dir is excluded as a harness copy, because every real skill collection checked (ECC, alirezarezvani, openspec, ponytail, paperclip, clawhub, openclaw) also ships a non-dot copy or is library-only; a blanket rule is simpler than a harness-name list that goes stale.
- Decided: translation dirs are matched by the 2-letter locale regex, not by a fixed list, because ECC alone has six locales and more will come; known limit: a real `docs/ui/` skill dir would be excluded, so add an explicit prefix rule only if that ever happens.
- Decided: `pi/` for ECC is a listed prefix, not a generic rule, because `pi` is not a dot-dir and appears in no other repo.
- Decided: `skill-excludes.txt` is read from `scripts/lib/` next to `find-skill-mds.sh` (not from `GRID_DIR`), because mock-grid tests use the real script and repo names that do not match any row.
- Decided: the openspec maintainer skills under `.agents/skills/` stop being wired, because the baseline comment says 12 workflow skills and already subtracts `release-openspec` as maintainer-only.
- Decided: `SKILLS.md` is regenerated only on a machine that has a personal `baseline-submodules.txt`; an agent without one leaves it and says so in the PR body, because the catalogue is built from the personal baseline and a wrong baseline would commit wrong output.
- Decided: CI runs `bash scripts/gate.sh`, not bare bats, so CI and the loop's verify step are the same command.
- Decided: keep `submodules: recursive` in CI for now, because `tests/lib/bats-core` and several tests need the submodules; workstream 3 revisits clone cost.
- Decided: `skills dir exists` skips when `CI=true`, and still fails on a real machine, because it is a machine-health check and a skipped test on a runner is honest where a forced pass is not.
- Decided: add a CI-only guard test `agent-factory venv exists when CI=true`, so a regression of the workflow fails instead of silently skipping 81 tests again.
- Decided: tests obtain the wired set by running the real `wire.sh` into a temp dir with `GRID_BASELINE`, falling back to `baseline-submodules.example.txt` when the personal baseline is absent, because that removes the duplicated discovery logic and also covers per-skill entries, which the old test never scanned.
- Decided: `GRID_BASELINE` is the only new `wire.sh` input for tests; `catalog.sh` is not changed to read it.
- Decided: `.nojekyll` at the repo root is the whole Pages fix in this change; if the first `main` build after merge still errors or the site exceeds the 1 GB Pages limit, a follow-up change moves Pages to an Actions deploy of `index.html` plus its assets only.
- Decided: all 22 SSH submodule URLs convert to HTTPS after `gh repo view <owner>/<repo> --json isPrivate` confirms each is public; a private one stays SSH and is named in the PR body. `tests/test_submodule_sources.bats` has no allowlist; if one is ever needed, that change adds it.
- Decided: `docs/SOURCES.md` is regenerated with `bash scripts/sources.sh` when a personal baseline exists; otherwise the implementer deletes only the SSH marker (` ᵍ`) and its footnote line by hand and says so in the PR body.
- Decided: every machine runs `git submodule sync --recursive` once after pulling the URL change; this is stated in `BOOTSTRAP.md` and in the HUMAN task.
- Decided: gstack has no tags or releases, so "latest upstream tag" means the upstream default-branch head commit at implementation time. The implementer records its `VERSION` in the commit message and refuses to proceed if that VERSION is lower than `1.91`.
- Decided: a bats test fixes a version floor (`repos/gstack/VERSION` major.minor at least 1.91, skipped when the submodule is uninitialised) so the pin cannot silently regress.
- Decided: the example baseline's gstack header count becomes 42 and a test asserts the header number equals the number of `gstack/` lines and that each entry resolves to a discovered skill; other repos' headers are not tested here.
- Decided: runtime handling is warn-only in `wire.sh` (exit 0), because wiring must stay safe on CI runners and on machines that deliberately skip the runtime.
- Decided: `wire.sh` owns the runtime-root link (`~/.claude/skills/gstack`), because its teardown deletes every symlink into the grid dir and would otherwise remove the link `./setup` makes on every run.
- Decided: the wrapper skips Homebrew `coreutils` and the Linux emoji font by default (`GSTACK_SKIP_COREUTILS=1`, `GSTACK_SKIP_FONTS=1`, overridable from the caller's environment), because the-grid scripts must not run `brew` or `sudo` implicitly; the cost is no `gtimeout` hang protection in `/codex` and `/autoplan`, and emoji tofu in `make-pdf` on Linux.
- Decided: the wrapper detects a global-settings change by SHA-256 of the file and exits 3 without reverting; reverting is gstack's `rollback`, which keeps its own backup.
- Decided: the wrapper removes only real dirs whose `SKILL.md` symlink points into the submodule; alias copies are listed, not deleted.
- Decided: `scripts/lib/runtimes.txt` format is pipe-separated text, not YAML, because `wire.sh` is bash and there is no YAML parser dependency.
- Decided: `runtime-setup.sh` is a standalone script, not a `wire.sh` flag, because wiring must stay offline and fast while setup downloads Chromium.
- Decided: bun is a prerequisite checked by the wrapper (`needs`), never installed by the-grid; the message points at gstack's own checksum-verified install instructions printed by `./setup`.
- Decided: docs touched are `CLAUDE.md` (wire.sh contract, runtime map, exclusion rule) and `BOOTSTRAP.md` (submodule sync, runtime step); no new top-level doc.

## Risks

- Venv tests have never run on a runner; a few may fail for environment reasons. Group 2 owns fixing them; a test that cannot run on a runner gets an explicit `skip` with a reason, never a deletion.
- `SKILLS.md` drifts until regenerated on a baseline machine (HUMAN group).
- `.nojekyll` may not be enough for Pages (see Decisions).
