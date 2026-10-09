## Context

- Today: submodules under `repos/` plus `scripts/wire.sh` symlinking skills into the skills dir. Wired set = `baseline-submodules.txt` + `machines/<host>.txt` + `machines/<host>.local.txt` (all gitignored; seeded from `baseline-submodules.example.txt` and `machines/example.txt`).
- `wire.sh` already writes `.wired.manifest` (TSV: kind, name, target, status, reason; sorted; no timestamp; rewritten only when changed) and has `--check`.
- ECC prior art (borrow ideas, not code): `schemas/install-state.schema.json` records, per install, the request, resolution, source commit and a list of operations (`sourceRelativePath`, `destinationPath`, `strategy`, `ownership`). `doctor` diffs disk against that state, `repair` re-applies, `uninstall` deletes only recorded operations. ECC's engine is about 2,500 LOC of Node plus 17 target adapters; the-grid needs the idea, not the engine.
- Microsoft APM prior art: `apm.yml` (manifest) plus `apm.lock` (resolved commit plus content hashes) plus policy allowlist plus `apm audit`. The-grid takes manifest/lock/hash. Policy and audit are workstream 4.
- Claude Code marketplace entries pin plugin sources with a 40-char `sha`; the lock uses the same pin shape so workstream 13 can reuse it.
- Constraints: macOS, Ubuntu, Arch; bash or Python 3 stdlib; shellcheck-clean; idempotent; tests never touch real `~/.claude`; no personal data in public files.

## Approach

```
maintainer machine (submodules)               any machine (no submodules)
  grid lock  ------------>  grid.lock  ----->  grid install
  (reads repos/*, wire.sh        |              fetch locked dirs @ sha (HTTPS)
   resolution of baseline)       |              verify tree + content hash
                                 |              place in .grid/store/<source>/<path>
                                 |              write .installed.manifest
                                 |              bash wire.sh  (store fallback)
  grid doctor / repair / uninstall / drift  <---- all read grid.lock + ledger
```

- `scripts/grid` is the only new entry point. `grid wire` is not added; users keep calling `wire.sh` (install calls it for them).
- The store mirrors the upstream repo layout: `.grid/store/<source>/<repo-relative skill path>/`. `wire.sh` can therefore reuse `find_skill_mds` and its entry grammar unchanged.
- The lock is computed by running `wire.sh` itself against the baseline into a throwaway dir (the same trick as `wire.sh --check`), so the wired set can never be interpreted differently by lock and wire.

### File formats

`grid.yaml` (tracked, hand-edited). A strict YAML subset: `#` comments, `key: scalar`, two-space nesting, nothing else (no lists, anchors, flow style, multi-line). Real YAML tools read it; `scripts/grid` parses it with about 30 lines of stdlib code and rejects anything outside the subset.

```yaml
version: 1
sources:                      # key = directory name under repos/
  anthropic:
    url: https://github.com/anthropics/skills.git
    ref: main                 # optional; default HEAD. Used only by `grid drift`.
  gstack:
    url: https://github.com/garrytan/gstack.git
    needs-setup: true         # optional; install prints a notice, never runs setup
wired:
  baseline: baseline-submodules.example.txt   # existing grammar, tracked file
```

`grid.lock` (tracked, generated, JSON, `sort_keys`, 2-space indent, trailing newline, skills sorted by name, `LC_ALL=C` byte order):

```json
{
  "lockVersion": 1,
  "skills": [
    {
      "hash": "sha256:9f2c...",
      "name": "docx",
      "path": "skills/docx",
      "sha": "53048666b05b4799081517d00e09e0a2dd688678",
      "source": "anthropic",
      "tree": "1d0e...40hex"
    }
  ]
}
```

- `sha`: the submodule gitlink commit recorded in the parent repo (`git ls-files -s repos/<source>`), 40 hex.
- `path`: repo-relative skill directory, forward slashes.
- `tree`: `git rev-parse <sha>:<path>`; lets `grid drift` compare against upstream without downloading blobs.
- `hash`: content hash, algorithm below.

Content hash: take every tracked file under the skill dir at `sha` (`git ls-tree -r`), sort by repo-relative path bytes, then SHA-256 over the concatenation of lines `<mode-class> <relpath> <sha256-of-file>\n` where mode-class is `x` for executable, `-` for regular, `l` for symlink (file hash = hash of the link target string). Prefix the digest `sha256:`. Mode class uses only the executable bit, so umask differences between OSes do not change it. A symlink whose target resolves outside the skill dir is a hard error at lock time.

`.installed.manifest` (gitignored, per machine; TSV; sorted `LC_ALL=C`; no timestamp; rewritten only when content changes; written atomically via temp file plus rename). Columns: `kind`, `name`, `source`, `sha`, `path`, `dest`, `hash`. Only `kind=skill` exists today. `dest` is relative to the grid dir (`.grid/store/<source>/<path>`), never absolute.

```
skill	docx	anthropic	53048666b05b4799081517d00e09e0a2dd688678	skills/docx	.grid/store/anthropic/skills/docx	sha256:9f2c...
```

- Relationship to `.wired.manifest`: that file stays exactly as `wire.sh` writes it (what is linked where). The ledger says what grid placed in the store. `doctor` joins the two by skill name.
- Header comment line is not used (keeps the format identical to `.wired.manifest`).

### Fetch mechanism

Git partial clone plus sparse checkout, one fetch per source:

```
git init -q <stage>
git -C <stage> remote add origin <url>
git -C <stage> sparse-checkout set --cone <path> <path> ...
git -C <stage> fetch -q --depth 1 --filter=blob:none origin <sha>
git -C <stage> checkout -q FETCH_HEAD
```

- Verify `git rev-parse HEAD` equals the locked sha.
- Verify `git rev-parse HEAD:<path>` equals the locked `tree`.
- Compute the content hash of the checked-out directory and compare to the lock.
- Only after all three pass, copy the directory (without `.git`) to the store.

Stage lives under `.grid/tmp/` and is removed on exit, success or failure.

### Install algorithm

1. Read `grid.yaml` and `grid.lock`; refuse any source URL not `https://` (`file://` allowed only when `GRID_ALLOW_FILE=1`, for tests).
2. Seed `baseline-submodules.txt` and `machines/<host>.txt` from the tracked examples if absent (same as `bootstrap.sh` steps).
3. Select entries: all lock entries minus `-source` and `-source/skill` lines found in the machine's baseline plus overlays (deny lines are scanned directly; `project:` lines ignored).
4. Skip an entry whose store directory already matches the lock hash and is in the ledger (re-run is a no-op).
5. Group remaining entries by source; fetch, verify, place (replace via rename of the old dir to a sibling `.old`, then delete it).
6. Write the ledger. Remove store directories that are in the old ledger but no longer selected.
7. Run `bash scripts/wire.sh`.
8. Print notices: sources flagged `needs-setup`; overlay entries naming skills absent from the lock (they are skipped, not an error).

### wire.sh changes (additive)

- `GRID_BASELINE` env var: path of the baseline file, default `$GRID_DIR/baseline-submodules.txt`. Used by `grid lock`.
- Repo discovery: iterate the sorted union of `repos/*/` names and `.grid/store/*/` names. For each name use `repos/<name>` if it is its own git checkout (`-e .git`), else `.grid/store/<name>` if it exists, else skip. Alphabetical precedence is preserved.
- `find_skill_mds` already falls back to plain `find` for a non-git dir, which is the store case.

### doctor / repair / uninstall

- `grid doctor` checks, in order, and exits 1 if any check reports a finding:
  1. `grid.yaml` parses; all URLs HTTPS; every source matches `.gitmodules` where one exists.
  2. Ledger vs lock: `missing` (locked and selected, not in ledger), `stale` (ledger sha or hash differs from lock), `extra` (in ledger, not in lock).
  3. Disk vs ledger: store directory `absent` or `modified` (recomputed hash differs).
  4. Links: runs `wire.sh --check` and reports its drift.
  Output: one line per finding `<check> <kind> <name> <detail>`; `--json` gives the same as a JSON array. A machine with no ledger (maintainer path) reports "no install ledger: maintainer mode" and runs only checks 1 and 4.
- `grid repair` re-fetches only `missing`, `stale`, `absent`, `modified` entries at the locked sha (same fetch, same verification), rewrites the ledger, runs `wire.sh`. It never touches paths outside `.grid/store/` and the grid-owned links. `extra` entries are removed from the store only with `--prune`.
- `grid uninstall` prints the plan (store dirs from the ledger, grid-owned links into the store, the ledger file) and does nothing without `--yes`. A store dir whose hash no longer matches the ledger is skipped and listed unless `--force`. Deletion rules: path must resolve under `<grid dir>/.grid/store/`; never follows symlinks; removes the empty parents it created. Links removed are only those in `SKILLS_DIR` whose target is under `.grid/store/`. It never touches submodules, `repos/`, `baseline-submodules.txt`, `machines/*`, or foreign links.

### Drift report

- For each distinct source in the lock: `git ls-remote <url> <ref|HEAD>` gives upstream head. If equal to the locked sha, the source is current (no further network).
- If different: `git fetch --depth 1 --filter=blob:none` of that head into a temp bare repo (trees only, no blobs), then for each wired skill of that source compare `rev-parse FETCH_HEAD:<path>` with the lock `tree`. Result per skill: `unchanged`, `changed`, `removed` (path gone), `unreachable`.
- Report is Markdown, written to `${GRID_REPORT_DIR:-$HOME/.grid/reports}/drift-YYYY-MM-DD.md` (UTC date) and copied to `drift-latest.md`. Contents: counts, then changed/removed skills by source with locked sha and upstream sha (short), then unreachable sources. No `/Users` paths, no hostnames in the body.
- Exit 0 always when the report was written (cron should not mail on drift); exit 2 on tool failure. `--quiet` suppresses stdout. Nothing in `grid.lock`, the store, or the ledger is touched.
- Maintainer response to drift is manual: `git submodule update --remote repos/<n>`, `grid lock`, review, PR.

### Scheduler

`grid schedule install|remove|status [--dry-run]`. Opt-in only; `install` (the command) never schedules anything.

| OS detected | Mechanism | Files |
|---|---|---|
| macOS (`uname` = Darwin) | launchd agent, weekly `StartCalendarInterval` (Monday 09:00 local) | `~/Library/LaunchAgents/io.the-grid.drift.plist`; load with `launchctl bootstrap gui/$UID` |
| Linux with a working `systemctl --user` | systemd user timer, `OnCalendar=Mon *-*-* 09:00`, `Persistent=true` | `~/.config/systemd/user/grid-drift.{service,timer}`; `systemctl --user enable --now grid-drift.timer` |
| anything else | cron | one crontab line tagged `# the-grid drift` (added/removed idempotently by tag) |

- Command run: `<abs path to scripts/grid> drift --quiet`. The absolute path is resolved at install time and written only into the generated local unit; nothing generated is committed.
- `GRID_SCHEDULE_DIR` overrides the unit/plist directory and, when set, no `launchctl`/`systemctl`/`crontab` command runs (tests).
- Headless Linux servers need lingering for user timers; `schedule install` prints `loginctl enable-linger` as a notice, never runs it.

### CLI shape

`scripts/grid`: one Python 3 stdlib file, `argparse` subcommands, no third-party imports, runs on Python 3.8+. Exit codes: 0 ok, 1 findings/drift, 2 usage or error. Flags shared everywhere: `--grid-dir`, `--skills-dir`, `--json` where output is structured. Environment contract is the same as `wire.sh`: `GRID_DIR`, `SKILLS_DIR`, `AGENTS_DIR`, `GRID_HOST`; plus `GRID_ALLOW_FILE`, `GRID_REPORT_DIR`, `GRID_SCHEDULE_DIR`. `grid path <source>/<skill>` prints the directory that skill resolves to (submodule checkout, else store), exit 1 if neither exists.

### #6 (agent-factory/skills/)

The issue was parked because candidate mapping is ambiguous and `wire.sh` already gives subagents ecosystem skills. Nothing in this change makes it more necessary. `grid path` gives a future resolve-by-name option (role-skill-map option C) a clean primitive that works on both submodule and install-only machines. The issue is closed as folded, with that note.

### #40 (skills-factory/)

The directory has no tracked files, so nothing is deleted in git. Public docs are edited so none names it. `index.html` "four factories" copy is left to workstream 12.

### Tests

- New bats files: `test_grid_manifest.bats`, `test_grid_lock.bats`, `test_grid_install.bats`, `test_grid_health.bats`, `test_grid_drift.bats`, `test_wiring_store.bats`, `test_gitmodules_https.bats`, `test_docs_factories.bats`.
- Fixtures: a throwaway upstream git repo built in the test with `git config uploadpack.allowFilter true` and `uploadpack.allowAnySHA1InWant true`, referenced as `file://`; real `GRID_DIR`, `SKILLS_DIR`, `AGENTS_DIR` and `HOME` all point at temp dirs (existing `common_setup` guard).
- No test touches the network or real launchd/systemd/crontab.

## Decisions

- Decided: git partial clone plus cone sparse checkout, not a tarball, because it downloads only the needed blobs (a tarball fetches the whole repo, and gstack/ECC are large), works against any HTTPS git host, and git itself verifies object integrity; requires git 2.25+ (Ubuntu 20.04, Apple git 2.39 and Arch all qualify).
- Decided: no tarball fallback, because two fetch paths double the test surface and GitHub accepts fetch-by-sha.
- Decided: one Python stdlib dispatcher `scripts/grid`, because it needs JSON, SHA-256, argparse and subprocess, which are painful in bash 3.2 on macOS; `wire.sh` stays bash.
- Decided: `grid.lock` is JSON, because stdlib reads it everywhere, diffs are clean with sorted keys, and APM and Claude Code pins are JSON/YAML-shaped too.
- Decided: `grid.yaml` is a restricted YAML subset parsed by hand, because PyYAML is not stdlib and the CLI must not need a venv.
- Decided: `grid.yaml` lists only sources referenced by the tracked baseline, because library-tier repos are not installable and `docs/SOURCES.md` already indexes them.
- Decided: the wired set in `grid.yaml` is a pointer to `baseline-submodules.example.txt`, because that is the tracked, shareable form of the existing grammar; the maintainer's personal baseline and overlays are never locked.
- Decided: the lock is generated by running `wire.sh` with `GRID_BASELINE=<example file>`, `GRID_HOST=lock-none` and a throwaway `SKILLS_DIR`, because it reuses the grammar and precedence rules instead of reimplementing them.
- Decided: lock `sha` comes from the parent gitlink, and `grid lock` fails if a submodule checkout is not at that commit or its skill dir is dirty, because the lock must describe committed state only.
- Decided: lock stores `tree` as well as `hash`, because drift detection then needs trees only, no blobs.
- Decided: content hash covers tracked files plus an executable-bit class, because that is what `find_skill_mds` considers the skill and avoids umask noise.
- Decided: the store is `.grid/store/<source>/<repo-path>` under the grid dir, gitignored, because placing files inside `repos/<name>` would dirty the uninitialised submodule path.
- Decided: `wire.sh` prefers a real submodule checkout over the store for the same source name, because the maintainer path must be unchanged.
- Decided: `grid install` fetches every lock entry not denied by the machine's manifests, because resolving the full machine set needs the files that do not exist yet; the cost is a few MB.
- Decided: the ledger is a new sibling `.installed.manifest` in the `.wired.manifest` TSV style, not extra columns in `.wired.manifest`, because `wire.sh` rewrites that file wholesale on every run.
- Decided: ledger paths are relative to the grid dir, because ledgers must contain no absolute or personal paths and must survive moving the dir.
- Decided: `uninstall` is dry-run unless `--yes`, because it deletes files (Rule 9 posture).
- Decided: `repair` never prunes without `--prune`, because `extra` entries may be intentional while a lock bump is in flight.
- Decided: drift report exit code is 0 when written, because scheduled jobs should not alarm on expected drift.
- Decided: drift reports go to `~/.grid/reports/`, matching the existing `~/.grid/runs.jsonl` convention, because they are per-machine and private.
- Decided: scheduling is a separate opt-in `grid schedule install`, never a side effect of `grid install`, because creating timers is a state change the user must ask for.
- Decided: weekly cadence, Monday 09:00 local, because upstream churn does not justify daily and a fixed time keeps the units trivial.
- Decided: `needs-setup` sources only print a notice, because gstack's runtime setup is workstream 1's job.
- Decided: `project:` entries and composed agents are out of the lock, because their output is generated locally by `compose.py` and needs a venv.
- Decided: #37 is done by rewriting URLs in `.gitmodules` after verifying each repo is public with `gh repo view --json isPrivate`; any private repo keeps SSH and is listed in the test allowlist.
- Decided: #6 is closed as folded without populating `agent-factory/skills/`, because the mapping is ambiguous, nothing needs it, and `grid path` covers the future need.
- Decided: #40 takes option 1 (drop `skills-factory`, "three factories"), as the issue recommends; only `README.md` (two lines), `automation-factory/README.md`, `project-factory/README.md` are edited here.
- Decided: gate integration is `grid lock --check` (skipped loudly if any locked submodule is uninitialised or python3 is missing), because a stale lock must fail the commit.
- Decided: `grid` is invoked by path (`scripts/grid`); no PATH install or alias, because shell config is per-machine and out of scope.

## Open questions (for Gareth)

- gstack skills may depend on files outside their own skill dir or on a built runtime; `install` fetches only the skill dirs. First install will show which are unusable without `./setup`. Is "gstack is maintainer-path only until workstream 1 lands" acceptable?
- Some skills may reference sibling shared files (for example `../shared/`). `grid lock` flags any `SKILL.md` that mentions `../` as a warning only; confirm warn-not-fail.
