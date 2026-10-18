## Context

- Today: submodules under `repos/` plus `scripts/wire.sh` symlinking skills into the skills dir. Wired set = `baseline-submodules.txt` + `machines/<host>.txt` + `machines/<host>.local.txt` (all gitignored; seeded from `baseline-submodules.example.txt` and `machines/example.txt`).
- `wire.sh` already writes `.wired.manifest` (TSV: kind, name, target, status, reason; sorted; no timestamp; rewritten only when changed), has `--check`, and `GRID_SKIP_CATALOG=1` (skips both the `.wired.manifest` write and the `SKILLS.md` refresh; `vetting` also skips its audit under it).
- `scripts/lib/find-skill-mds.sh` lists tracked `SKILL.md` files in a git checkout and falls back to plain `find` in a directory that is not its own checkout (an uninitialised submodule dir). `foundations#1` adds exclusions to both branches.
- An uninitialised submodule dir `repos/<n>` is an empty directory tracked as a gitlink. Verified with git 2.39: files placed inside it do not appear in `git status`, `git add -A` ignores them, and `git add <file>` refuses ("Pathspec is in submodule"). `git submodule update --init repos/<n>` refuses a non-empty dir with a clear error and changes nothing.
- The fetch recipe below (partial clone, cone sparse checkout, checkout of the fetched sha) was RAN on git 2.39.5 (Apple Git-154), including a top-level `file://` fetch without `-c protocol.file.allow=always`. It is READ-only for git 2.25 (Ubuntu 20.04), 2.34 (22.04), 2.43 (24.04) and current Arch: the `init --cone` then `set` sequence is the documented recipe on all of them, but the first cross-OS run is the operator's to confirm.
- Schedule files are rendered by the one shared renderer `scripts/lib/render-schedule.sh` owned by `loops#3` (G2), which supports daily-at-hour and weekly (weekday plus hour) for a launchd plist, a systemd user timer and a cron line. This change depends on `loops#3` for it and renders no schedule text of its own.
- Prior art (ideas, not code): ECC's install-state (`doctor` diffs disk against recorded operations, `uninstall` deletes only recorded operations); Microsoft APM's manifest plus lock with content hashes. Claude Code marketplace entries pin sources with a 40-char `sha`; the lock uses the same pin shape so `plugin-marketplace` can reuse it later.
- Cross-change inputs this change consumes (none are re-introduced here):
  - `foundations#2`: `GRID_BASELINE` (path override for the baseline manifest in `wire.sh`).
  - `foundations#8`: `GRID_DRY_HOME=<tmp>` in `wire.sh` redirects every home-derived target (G1).
  - `foundations#3`: `.gitmodules` URLs are HTTPS.
  - `foundations#5`: `scripts/lib/runtimes.txt` (pipe-separated, first field = repo name).
  - `vetting#1`: `scripts/lib/miniyaml.py` (`loads(text)`, `ParseError(line, msg)`), `scripts/audit.py`, `policy.yaml`.
  - `vetting#2`: `scripts/audit.py --check-url URL` (exit 0 allowed, 1 not allowed).
  - `loops#3`: `scripts/lib/render-schedule.sh` (G2).
  - `vetting#3`: `scripts/audit.sh --owned|--wired|--gate`.
  - Grammar owned elsewhere and passed through untouched: `project:<name>` (today), `rules:<pack>` (`rule-packs`), `harness:<name>` (`multi-harness`), each with a `-` form.

## Approach

```
maintainer machine (submodules)               any machine (no submodules)
  grid lock  ------------>  grid.lock  ----->  grid install
  (runs wire.sh on the           |              fetch locked dirs @ sha (HTTPS) into .grid-tmp/
   tracked baseline)             |              verify sha + tree + content hash
                                 |              audit.py on the staged copy
                                 |              place at repos/<source>/<path>
                                 |              write ~/.grid/installed.manifest
                                 |              GRID_NO_CATALOG=1 bash wire.sh  (unchanged wiring)
  grid doctor / repair / uninstall / drift  <---- all read grid.lock + ledger
```

- `scripts/grid` is the only new entry point. Users keep calling `wire.sh`; `install`, `repair` and `uninstall` call it for them.
- Installed skills land at the same path a submodule checkout would give them, inside the empty submodule dir. `wire.sh`, `find_skill_mds`, `.wired.manifest`, `catalog.sh`, the `vetting` allowlist (paths like `repos/<source>/...`) and the `foundations` exclusions all work unchanged. A source dir that is a real checkout (`repos/<n>/.git` exists) is never written to.

### File formats

`grid.yaml` (tracked, hand-edited), read with `vetting`'s `scripts/lib/miniyaml.py`:

```yaml
# grid.yaml - where wired skills come from and which set is wired by default.
version: 1
sources:                      # key = directory name under repos/
  anthropic:
    url: https://github.com/anthropics/skills.git
    ref: main                 # optional; default HEAD. Used only by `grid drift`.
wired:
  baseline: baseline-submodules.example.txt   # existing grammar, tracked file
```

- Allowed top-level keys: `version` (must be `1`), `sources` (map), `wired` (map with required `baseline`). Allowed source keys: `url` (required), `ref` (optional).
- Reserved top-level keys `rules` and `harnesses`: accepted, ignored, one stderr notice `grid: grid.yaml key '<k>' is reserved and ignored by this version`. Any other unknown key, at any level, is exit 2 naming the key.

Typed entries (forward compatibility; the reservation this change makes):

- In every file of the wired set (`wired.baseline`, `machines/<host>.txt`, `machines/<host>.local.txt`), an entry whose text before the first `/` contains `:` is a typed entry: `<kind>:<value>` or `-<kind>:<value>`. Known kinds today: `project`; added by later changes: `rules`, `harness`, `hook`.
- `grid` handles only untyped entries (`repo`, `repo/skill`, `-repo`, `-repo/skill`). Every typed entry, of any kind, known or not, is ignored by `grid lock`, `grid install` and `grid doctor` and left for `wire.sh`. Adding a kind therefore needs no change to `grid` or to `grid.yaml`'s `version`.
- `grid.lock` entries carry `kind`. This change writes only `"kind": "skill"`. A reader that meets another kind skips that entry with one stderr notice per kind and never fails, so a later change can lock upstream rule packs (`"kind": "rule"`) under `lockVersion` 1. The lock never carries a harness: harness choice is a wiring concern, and placed files are harness-neutral.
- The ledger's first column is the same `kind`, with the same skip rule.

`grid.lock` (tracked, generated, JSON, `sort_keys=True`, 2-space indent, trailing newline, entries sorted by `(kind, name, source)` in byte order):

```json
{
  "lockVersion": 1,
  "entries": [
    {
      "hash": "sha256:9f2c...",
      "kind": "skill",
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
- `path`: repo-relative skill directory, forward slashes, never empty.
- `tree`: `git -C repos/<source> rev-parse <sha>:<path>`; lets `grid drift` compare against upstream without blobs.
- `hash`: content hash, below.

Content hash: list the tracked files of the skill tree with `git ls-tree -r -z <sha>:<path>` (NUL-delimited, so any filename is safe; the paths are relative to the skill dir), drop excluded names (below), sort by relative path bytes, then SHA-256 over the concatenation of lines `<class> <relpath> <sha256-of-content>\n`, where class is `x` (mode 100755), `-` (100644) or `l` (120000; content = the link target string). Blob contents come from ONE `git cat-file --batch` process per source (the gate runs `lock --check` on every commit, so thousands of per-file processes are not acceptable). Prefix `sha256:`. A mode 160000 entry (nested submodule) inside a skill is a hard error at lock time (exit 2 naming the path).

- On disk (install, doctor) the same lines are computed with `os.walk(followlinks=False)`: every file under the dir is included (so an added file changes the hash). An entry is class `l` if `os.path.islink` (this includes symlinks to directories, which `os.walk` lists under `dirnames`, so check both lists) with content `os.readlink`; else `x` if any execute bit is set, else `-`.
- Excluded on BOTH sides, so the two computations always agree: any file named `.DS_Store`, any directory named `__pycache__` (and everything below it), any file ending `.pyc`. Reason: Finder writes `.DS_Store` into any folder the operator browses and Python writes `__pycache__` when a skill's helper module is imported; neither is a user edit.
- A symlink whose target resolves outside the skill dir is a hard error at lock time (exit 2).
- Staged checkouts set `core.autocrlf=false` and `core.eol=lf` in the throwaway repo's own config so a user's global line-ending settings cannot change bytes. A fetched `.gitattributes` that forces other conversions fails verification loudly (hash mismatch names the skill); that is acceptable.

Ledger `${GRID_STATE_DIR:-$HOME/.grid}/installed.manifest` (machine-local; TSV; sorted `LC_ALL=C`; no timestamp; written atomically via temp file plus `os.replace`, and only when content changes). Columns: `kind`, `name`, `source`, `sha`, `path`, `dest`, `hash`. `dest` is relative to the grid dir (`repos/<source>/<path>`).

```
skill	docx	anthropic	53048666b05b4799081517d00e09e0a2dd688678	skills/docx	repos/anthropic/skills/docx	sha256:9f2c...
```

- One installed grid per user account: the ledger describes the grid dir `grid` is run against. `doctor` against a different clone reports its rows `absent`; `uninstall` containment (below) keeps a mismatch harmless.
- Relationship to `.wired.manifest`: that file stays exactly as `wire.sh` writes it (what is linked where). The ledger says what `grid` placed. `doctor` joins them by `dest`.

### Input validation

`grid.lock` and `grid.yaml` arrive through a PR and `dest` is built from them, so every field is validated when the file is read (exit 2 naming the entry, before any network access or write):

- `source`: matches `^[A-Za-z0-9][A-Za-z0-9._-]*$` and has an entry under `sources`.
- `path`: not empty, not absolute, no `\`; split on `/`, every component matches `^(?!-)(?!\.\.?$)[A-Za-z0-9._@+-]+$` (dot-directories such as `.claude/skills/x` are allowed; `..`, `.`, a leading `-`, spaces, tabs, newlines and control characters are not). RAN: all 2528 tracked skill directories in the 35 submodules initialised on the maintainer machine match. `grid lock` applies the same check to the paths it discovers and exits 2 naming one that fails.
- `sha` and `tree`: exactly 40 lowercase hex characters. `hash`: `sha256:` plus 64 lowercase hex. `kind`, `name`: non-empty, no tab or newline.
- `grid.yaml` `ref`: matches `^[A-Za-z0-9][A-Za-z0-9._/-]*$`.
- After building `dest = repos/<source>/<path>`, `os.path.commonpath` of `realpath(<grid>/<dest>)` and `realpath(<grid>/repos/<source>)` must equal the latter; this is the same containment test `uninstall` uses and is applied before every write or delete.

Reason: without it a lock entry such as `path: ../../../.ssh` would make `install` write, and `uninstall` delete, outside `repos/<source>`, and a leading `-` would reach `git sparse-checkout set` as an option.

### Fetch mechanism

One staging run dir per invocation: `<grid>/.grid-tmp/<pid>/` (gitignored), removed in a `finally`; `SIGTERM` is turned into `sys.exit(143)` so the `finally` runs under a scheduler kill. At start, delete any `<grid>/.grid-tmp/*` entry older than one day (leftovers of a `SIGKILL`). Per source:

```
git init -q <run>/repos/<source>
git -C <run>/repos/<source> config core.autocrlf false
git -C <run>/repos/<source> config core.eol lf
git -C <run>/repos/<source> remote add origin <url>
git -C <run>/repos/<source> fetch -q --depth 1 --filter=blob:none origin <sha>
git -C <run>/repos/<source> sparse-checkout init --cone
git -C <run>/repos/<source> sparse-checkout set <path> <path> ...
git -C <run>/repos/<source> checkout -q FETCH_HEAD
```

- Every git child runs with `LC_ALL=C`, `GIT_TERMINAL_PROMPT=0` (an unreachable or private URL fails instead of waiting on a prompt that an unattended job can never answer), the variables `GIT_DIR`, `GIT_WORK_TREE`, `GIT_INDEX_FILE`, `GIT_PREFIX` removed (so a call made from inside a git hook still addresses the repo given by `-C`), and a 600-second timeout (`subprocess.run(timeout=...)`; a timeout is a failed fetch for that source).
- `grid` checks `git --version` once: below 2.25 it exits 2 with `grid: git 2.25 or newer is required (found <v>)`.
- Cone mode also materialises the root-level files and the files directly inside each ancestor directory of a path; only the `<path>` directories are verified and placed, the rest is discarded with the run dir.
- Verify `rev-parse HEAD` equals the locked `sha`, `rev-parse HEAD:<path>` equals `tree`, and the on-disk content hash of `<run>/repos/<source>/<path>` equals `hash`. A mismatch fails that entry. A failed fetch fails every entry of that source with `grid: <source>: cannot fetch pinned commit <short sha> (upstream may have removed it; the maintainer must re-run grid lock)`.
- When `GRID_TRACE_FETCH` is set, append one line `<source> <sha>` to that file per fetch (tests use it to prove a no-op re-run).

### Vetting the staged copy

- After verification, one call per source (interpreter = `sys.executable`): `python3 <grid>/scripts/audit.py --format json --root <run> --grid-dir <grid> <run>/repos/<source>/<path> ...` (every verified path of that source). Reported paths therefore read `repos/<source>/...`, so `CURATION.md` allowlist entries written for the maintainer path match.
- Exit 0: all paths pass. Exit 1: parse the JSON; an entry fails when any finding has `severity: "high"`, `allowed: false` and a `path` starting with `repos/<source>/<entry path>/`; other entries of the source pass. Exit 2 or unparseable output: every entry of that source fails.
- `GRID_AUDIT=warn` (same variable `vetting` gives `wire.sh`): failing entries are placed anyway with a stderr warning naming them.
- No `scripts/audit.py` or no `policy.yaml` in the grid dir: exit 2 with `grid: refusing to place unvetted content (no audit.py/policy.yaml); set GRID_AUDIT=warn to override`, before any network access (checked in install step 1). With `GRID_AUDIT=warn`: print `grid: audit SKIPPED (no audit.py/policy.yaml) - placed unvetted` to stderr and continue.
- Source check (install and repair step 1, before any network access): for every source that has a selected entry, run `python3 <grid>/scripts/audit.py --check-url <url>`. Non-zero exit is exit 2 naming the source and the reason `audit.py` printed; with `GRID_AUDIT=warn` it is a stderr warning instead. A `file://` URL (only reachable with `GRID_ALLOW_FILE=1`, tests only) skips the check with one stderr notice `grid: <source>: file:// source, --check-url skipped`. When `audit.py`/`policy.yaml` are absent under `GRID_AUDIT=warn`, the source check is skipped with the audit SKIPPED notice.
- `grid audit [args...]` runs `bash <grid>/scripts/audit.sh args...` with the same environment and returns its exit code. No other logic.

### Install algorithm

`grid install [--dry-run] [--force]`. `--dry-run` runs steps 1-6, prints what would be fetched, placed and removed, and exits 0 without any network access or write (no seeding, no ledger, no wire.sh).

1. Read `grid.yaml` and `grid.lock` and validate them (Input validation); refuse (exit 2, before any network) any source URL not `https://` (`file://` allowed only when `GRID_ALLOW_FILE=1`, for tests). Check the git version floor. Require `scripts/audit.py` and `policy.yaml` and run the `--check-url` source check (Vetting the staged copy) for every source with a selected entry (computed after steps 3-5), all before any network access.
2. Seed `baseline-submodules.txt` from `baseline-submodules.example.txt` and `machines/<host>.txt` from `machines/example.txt` if absent (host = `GRID_HOST`, else `socket.gethostname().split(".")[0]`, which equals `hostname -s` and needs no external `hostname` binary; same file names as `bootstrap.sh`). Never overwrites an existing file.
3. Select `kind: skill` lock entries, minus untyped deny lines (`-source`, `-source/skill` matched against `source` and the basename of `path`) found in the baseline and both overlays. Typed lines are ignored.
4. Drop entries whose source is listed in `scripts/lib/runtimes.txt` (first `|` field, trimmed; absent file = none) and print once per source: `grid: <source> needs a runtime; use the maintainer path for it: git submodule update --init repos/<source> && bash scripts/runtime-setup.sh <source>`.
5. Drop entries whose `repos/<source>/.git` exists (maintainer checkout) and print once per source `grid: <source> is a submodule checkout; left to the maintainer path`.
6. Classify each remaining entry by its `dest` and the old ledger:
   - `current`: in the ledger with the locked `sha` and `hash`, `dest` exists and re-hashes to `hash`. Nothing to do (re-run is a no-op, no fetch).
   - `adopt`: not in the ledger (or in it with a different `sha`), `dest` exists and re-hashes to the locked `hash`. Record it in the ledger, no fetch (recovers from a crash between placing and writing the ledger, or a lost ledger).
   - `protected`: `dest` exists and re-hashes to neither the ledger `hash` nor the locked `hash` (a user edit, or a directory grid did not write). Not touched; reported as `grid: <name>: <dest> differs from what grid placed; left alone (grid repair --force replaces it)`; counts as a failed entry (exit 1). With `--force` it is treated as `replace`.
   - `fetch`: `dest` absent, or in the ledger with a different `sha`/`hash` and an unmodified directory (a lock bump).
7. Group the `fetch` and `replace` entries by source; fetch, verify, audit; place each passing entry: copy its verified staged directory (`<run>/repos/<source>/<path>`) with `shutil.copytree(src, <run>/place/<dest>, symlinks=True)` (links are copied as links, never followed), repeat the lock-time symlink-escape check on `<run>/place/<dest>`, recompute its on-disk content hash and fail the entry (nothing placed, error names it) on any escape or a hash different from the lock, then rename `<run>/place/<dest>` (same filesystem as the grid dir) to `<grid>/<dest>`. If `dest` exists, first rename it into `<run>/old/<n>` (inside the staging dir, never beside `dest`: a leftover `*.grid-old` next to a skill would be found by `find_skill_mds`'s plain-`find` fallback and wired as a skill). Create `repos/<source>` and missing parents if absent.
8. Remove dirs that are in the old ledger but no longer selected, with the same containment and modified-directory protection as `uninstall` (a modified one is kept and reported).
9. Write the ledger: every `current`, `adopt` and newly placed entry, plus rows of unknown `kind` copied through verbatim. This happens even when some entries failed (exit 1), so the ledger always says what is on disk.
10. Run `GRID_NO_CATALOG=1 bash <grid>/scripts/wire.sh` (env `GRID_DIR`, `SKILLS_DIR`, `AGENTS_DIR`, `GRID_HOST` passed through; `GRID_DIR` is the realpath described under CLI shape). A non-zero exit from it is reported and makes `install` exit 1.
11. Print a notice for any untyped overlay entry naming a skill absent from the lock (skipped, not an error).
12. Exit 0 if every selected entry is placed or already current, else 1.

### wire.sh change (one variable)

- `GRID_NO_CATALOG=1` skips step 4 (the `catalog.sh` refresh) only; `.wired.manifest` is still written and the `vetting` audit still runs. Documented in the header env list. Reason: on an install-path machine most library repos are empty, so a refresh would rewrite the tracked `SKILLS.md` wrongly.

### doctor / repair / uninstall

- `grid doctor [--json]` checks, in order, and exits 1 if any check reports a finding:
  1. `manifest`: `grid.yaml` parses; all URLs HTTPS; every source URL equals the `.gitmodules` URL for `repos/<name>` where one exists.
  2. `ledger`: `missing` (selected per install steps 3-5 but not in ledger), `stale` (ledger `sha` or `hash` differs from lock), `extra` (in ledger, not in lock).
  3. `disk`: ledger `dest` `absent`, or `modified` (on-disk hash differs from ledger `hash`).
  4. `links`: runs `GRID_SKIP_AUDIT=1 bash scripts/wire.sh --check`; each drift line it prints is a finding.
  Output: one line per finding `<check> <kind> <name> <detail>`, sorted; `--json` prints a JSON array of objects `{check, kind, name, detail}`. No ledger file: print `no install ledger: maintainer mode` and run only checks 1 and 4.
- `grid repair [--prune] [--force] [--dry-run]` is `install` step 1 (validation, scanner-present and `--check-url` checks) plus steps 3-12 restricted to what doctor reports: it re-fetches only `missing`, `stale` and `absent` entries at the locked sha (same fetch, verify, audit and place), rewrites the ledger and runs `wire.sh` as in install step 10. A `modified` entry is re-fetched only with `--force` (otherwise listed and counted as failed, exit 1), so a repair never silently discards an edit. `extra` entries are removed only with `--prune`.
- `grid uninstall [--yes] [--force]` prints the plan (ledger dirs, links in `SKILLS_DIR` that point at a ledger dir, the ledger file) and changes nothing without `--yes`. Link matching resolves both sides: a link belongs to a row when `os.path.realpath(os.path.join(os.path.dirname(link), os.readlink(link)))` equals `os.path.realpath(<grid>/<dest>)` (the realpath form is required because macOS temp and home paths pass through symlinks such as `/var` to `/private/var`, so a string compare of `readlink` output can silently match nothing). Containment for every deletion: `os.path.realpath(<grid>/<dest>)` must lie under `realpath(<grid>/repos/<source>)` (via `os.path.commonpath`), `repos/<source>/.git` must not exist, and the dir itself must not be a symlink (`os.lstat`). A dir whose on-disk hash differs from the ledger is skipped and listed unless `--force`. Links are removed before directories. After removing a dir, remove now-empty parents up to but not including `repos/<source>`. Never touches `.git` dirs, `baseline-submodules.txt`, `machines/*`, foreign links or real dirs in `SKILLS_DIR`. A second run reports `nothing to remove` and exits 0.

### Drift report

- Per distinct source in the lock: `git ls-remote <url> <ref or HEAD>`; the head is the first output line whose name is exactly `HEAD`, `refs/heads/<ref>` or `refs/tags/<ref>^{}` (peeled) / `refs/tags/<ref>`, in that preference order. No such line (ref not found) is `unreachable` with detail `ref not found`. Equal to the locked sha: all its entries `unchanged`, no fetch.
- Different: into a temp bare repo under `.grid-tmp/<pid>/`, `git fetch --depth 1 --filter=blob:none origin <head>` (trees only), then per entry compare `rev-parse FETCH_HEAD:<path>` with the lock `tree`: `unchanged`, `changed`, or `removed` (path gone). `ls-remote` or fetch failure: the source is `unreachable`.
- Report: Markdown, written to `${GRID_STATE_DIR:-$HOME/.grid}/reports/drift-YYYY-MM-DD.md` (UTC date) and copied to `drift-latest.md` in the same dir. Contents: counts per class, then changed and removed entries grouped by source with short locked and upstream shas, then unreachable sources. No absolute paths, no hostname.
- Exit 0 whenever the report was written (a schedule must not alarm on expected drift); exit 2 on a tool failure. `--quiet` suppresses stdout. `grid.lock`, the ledger and every `repos/` dir are untouched.
- Maintainer response is manual: `git submodule update --remote repos/<n>`, `grid lock`, review, PR.

### Schedule

`grid schedule install|remove`. Opt-in only; `grid install` never schedules anything. Every body is rendered by `loops#3`'s `scripts/lib/render-schedule.sh` (signatures in `loops` design.md "Scheduling"), called in its executed form `bash <grid>/scripts/lib/render-schedule.sh render_<fn> ARGS…`; `scripts/grid` writes the printed text to the file unchanged and builds no schedule text itself. Nothing is activated: the activation command is printed, and `launchctl`/`systemctl`/`crontab`/`loginctl` are never run (the read-only probe below excepted).

Inputs, resolved by `scripts/grid` to absolute literal paths before the call (the renderer rejects `$`):
- `<grid>`: the realpath grid dir; also WORKDIR.
- SCHEDULE: `weekly:Mon:09:00`.
- LOG_DIR: `${GRID_STATE_DIR:-$HOME/.grid}/logs`; LOG_FILE: `<LOG_DIR>/grid-drift.log`.
- CMD `/usr/bin/env`, ARGs `python3 <grid>/scripts/grid drift --quiet`.

OS: `GRID_OS` override, else `uname -s`; Linux is systemd when `systemctl --user show-environment >/dev/null 2>&1` succeeds (or `GRID_OS=Linux`), else falls to the cron row.

| OS | Renderer calls → files written | Printed command |
|---|---|---|
| `Darwin` | `render_launchd_plist io.the-grid.drift <HOME> <grid> <LOG_DIR> weekly:Mon:09:00 /usr/bin/env python3 <grid>/scripts/grid drift --quiet` → `${LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}/io.the-grid.drift.plist`. `PATH`, `HOME`, `WorkingDirectory` and the log paths are whatever `render_launchd_plist` emits; `scripts/grid` runs `mkdir -p <LOG_DIR>` (launchd does not create it). | `render_activation_commands launchd <plist path>` |
| `Linux` (systemd user) | `render_systemd_service "grid drift report" <grid> 600 /usr/bin/env python3 <grid>/scripts/grid drift --quiet` → `${SYSTEMD_USER_DIR:-$HOME/.config/systemd/user}/grid-drift.service`; `render_systemd_timer "Weekly grid drift report" grid-drift.service weekly:Mon:09:00` (no RANDOM_DELAY) → `grid-drift.timer` | `render_activation_commands systemd grid-drift.timer`, plus the `loginctl enable-linger "$USER"` note (a user timer does not run while logged out without it) |
| anything else | `render_crontab_line weekly:Mon:09:00 <LOG_FILE> <grid> /usr/bin/env python3 <grid>/scripts/grid drift --quiet` → no file | `render_activation_commands cron <that line>` |

- The cron line carries no tag; it is identified by the substring `scripts/grid drift`.
- `schedule install` exits 2 with a message, writing nothing, when the renderer returns 2 (any PATH-like argument, including `<grid>`, `<HOME>` or `<LOG_DIR>`, contains a character outside `[A-Za-z0-9_./@+-]`): clone to a plain path to use the schedule (G2; the renderer does no escaping).
- `install` writes byte-identical files on a second run (no timestamps). `remove` deletes exactly those files (or prints: delete the crontab line containing `scripts/grid drift`) and prints the deactivation command (`launchctl bootout gui/$(id -u)/io.the-grid.drift`; `systemctl --user disable --now grid-drift.timer`).
- Decided: the schedule is exactly the renderer calls above (SCHEDULE `weekly:Mon:09:00`, LOG_DIR `${GRID_STATE_DIR:-$HOME/.grid}/logs`, CMD `/usr/bin/env`, ARGs `python3 <grid>/scripts/grid drift --quiet`), because `loops#3` is the one renderer (G2) and restating its output here would drift from it.
- Decided: Linux systemd detection is `systemctl --user show-environment >/dev/null 2>&1`, the same probe `budget-and-usage` uses.
- Decided: no `# the-grid drift` crontab tag, because `render_crontab_line` emits no comment; the substring `scripts/grid drift` identifies the line.

### CLI shape

`scripts/grid`: one Python 3 stdlib file (plus `scripts/lib/miniyaml.py` via `sys.path` from `__file__`, as `audit.py` does), `argparse` subcommands, Python 3.8+. It sets `sys.dont_write_bytecode = True` before importing `miniyaml` so running it never creates `__pycache__` in the repo. Python 3.8 floor means: no `str.removeprefix`/`removesuffix`, no `dict | dict`, no `list[str]`/`dict[str, str]` in annotations evaluated at runtime (use `typing` or none), no `match`. Exit codes: 0 ok, 1 findings or failed entries, 2 usage or error, 3 (`lock --check` only) not checkable here. Shared flags: `--grid-dir` (else `GRID_DIR`, else parent of `scripts/`), `--skills-dir` (else `SKILLS_DIR`). The grid dir is resolved with `os.path.realpath` once and that value is used everywhere, including as `GRID_DIR` for child `wire.sh` runs, so link targets are realpaths and every compare is safe. Environment: `GRID_DIR`, `SKILLS_DIR`, `AGENTS_DIR`, `GRID_HOST`, `GRID_STATE_DIR`, `GRID_ALLOW_FILE`, `GRID_TRACE_FETCH`, `GRID_AUDIT`, `GRID_OS`, `LAUNCH_AGENTS_DIR`, `SYSTEMD_USER_DIR`. Every child process runs with `LC_ALL=C`. The ledger, lock and reports are written with `\n` line endings via `newline="\n"`.

### grid lock

- Runs `wire.sh` with `GRID_SKIP_CATALOG=1 GRID_SKIP_AUDIT=1 GRID_BASELINE=<grid>/<wired.baseline> GRID_HOST=__baseline__ GRID_HARNESS=claude GRID_DRY_HOME=<tmp>/home HOME=<tmp>/home` and no other target override: per the `foundations#8` contract (G1), `GRID_DRY_HOME` makes `wire.sh` export `HOME=$GRID_DRY_HOME` and FORCE `SKILLS_DIR`, `AGENTS_DIR`, `CLAUDE_CONFIG_DIR`, `RULES_DIR` and the harness paths under it, ignoring inherited values, so `grid lock` passes no `SKILLS_DIR`/`AGENTS_DIR`/`RULES_DIR`/`GRID_HARNESS_HOME`/`CLAUDE_CONFIG_DIR`. `HOME` is also set for this child so any `~`-relative write before `wire.sh` applies the contract lands in the temp dir. Results are read from `<tmp>/home/.claude/skills`. Lock and wire can never read the baseline differently and nothing outside the temp dir is written.
- Decided: `grid lock` sets only `GRID_DRY_HOME` and `HOME` for the home redirect and reads `<tmp>/home/.claude/skills`, because `foundations#8` forces every home-derived target under `GRID_DRY_HOME`; passing its own `SKILLS_DIR` would be ignored and reading `<tmp>/skills` would yield an empty lock.
- Takes every symlink in `<tmp>/home/.claude/skills` whose target is `<grid>/repos/<source>/<path>` (string compare is safe: `<grid>` is the realpath `grid` itself passed as `GRID_DIR`) with a non-empty `path` and a `SKILL.md` in the target (this excludes the `foundations` runtime-root link). Each discovered `path` must pass Input validation.
- `sha` from `git ls-files -s repos/<source>` (the index, so a staged pointer bump is seen before commit); exit 2 naming the source if `git -C repos/<source> rev-parse HEAD` differs or `git -C repos/<source> status --porcelain -- <path>` is non-empty. Writes `grid.lock` atomically.
- Warns on stderr (never fails) when a `SKILL.md` contains `../`.
- `grid lock --check` regenerates in memory, exits 1 listing added, removed and changed entries, and also runs doctor check 1 plus "every untyped baseline repo has a `sources` entry". It exits 3 (not 1 or 2) with `grid: lock --check not possible here: repos/<source> is not a checkout` when any source named in `grid.lock` has no `repos/<source>/.git`; `gate.sh` maps exit 3 to a loud skip, so no JSON parsing is needed in bash.
- Any later change that edits `baseline-submodules.example.txt` or moves a `repos/*` pointer must run `python3 scripts/grid lock` in the same PR; the gate then enforces it.

### #6 (agent-factory/skills/)

Parked because the candidate mapping is ambiguous and `wire.sh` already gives subagents ecosystem skills. Nothing here makes it more necessary, and installed skills sit at the same `repos/<source>/<path>` as on the maintainer path, so any future resolve-by-name works on both. Closed as folded with that note.

### #40 (skills-factory/)

The directory has no tracked files, so nothing is deleted in git. Public docs are edited so none names it. `index.html` copy is left to `front-door`.

### Tests

- New bats files: `test_grid_manifest.bats`, `test_grid_lock.bats`, `test_grid_install.bats`, `test_grid_health.bats`, `test_grid_drift.bats`, `test_docs_factories.bats`; shared builder `tests/helpers/grid_fixture.bash`.
- Fixture: a throwaway upstream git repo built in the test with `git config uploadpack.allowFilter true` and `uploadpack.allowAnySHA1InWant true`, referenced as `file://` with `GRID_ALLOW_FILE=1`; a fixture grid dir with `repos/<src>` as an empty dir and a copy of `scripts/wire.sh`, `scripts/grid`, the whole `scripts/lib/` directory (so exclusion lists and the runtime map that `wire.sh` reads come along), and, for install tests, `policy.yaml`, `CURATION.md`, `scripts/audit.py` and `scripts/audit.sh` (`wire.sh` calls `audit.sh` once `policy.yaml` exists). The fixture has NO `.gitmodules`, so the scanner makes no source checks against a `file://` URL. `GRID_DIR`, `SKILLS_DIR`, `AGENTS_DIR`, `GRID_STATE_DIR`, `LAUNCH_AGENTS_DIR`, `SYSTEMD_USER_DIR`, `HOME`, `CLAUDE_CONFIG_DIR` and `GRID_HARNESS_HOME` all live under `mktemp -d` (plus `common_setup`). `GIT_CONFIG_GLOBAL` and `GIT_CONFIG_SYSTEM` point at `/dev/null` so a developer's own git config (for example `url.<ssh>.insteadOf`) cannot change a test. No `-c protocol.file.allow=always` is used: a top-level `file://` fetch does not need it (RAN, git 2.39.5).
- Portability rules for test code (macOS runs bash 3.2 and BSD tools; Ubuntu and Arch run GNU): no `mapfile`/`readarray`, `declare -A`, `${x,,}`; no `sed -i`, `stat -c`/`-f`, `date -d`/`-v`, `readlink -f`, `shasum`/`sha256sum`. Anything needing file metadata or a digest goes through `python3` helpers in `grid_fixture.bash`: `tree_digest <dir>` (sorted relative paths plus content hashes, used for "byte-identical before and after") and `file_id <path>` (prints `st_ino:st_mtime_ns`; because the ledger is replaced with `os.replace`, a rewrite always changes the inode, so equality proves "not rewritten" even on a coarse-timestamp filesystem).
- At least one fixture grid is reached through a symlinked path (`ln -s <real> <link>`; macOS temp dirs already live behind `/var` to `/private/var`) to prove realpath handling in `lock`, `install` and `uninstall`.
- No test touches the network, real `~/.grid`, or runs `launchctl`/`systemctl`/`crontab`.
- Python floor check (no artefacts, unlike `py_compile`): `python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read(), feature_version=(3, 8))' scripts/grid`. It catches syntax newer than 3.8, not newer library calls; the portability list under CLI shape covers those by review.

## Decisions

- Decided: git partial clone plus cone sparse checkout, not a tarball, because it downloads only the needed blobs, works against any HTTPS git host, and git verifies object integrity; `sparse-checkout init --cone` then `set` works from git 2.25 (Ubuntu 20.04) through current Apple git and Arch.
- Decided: no tarball fallback, because two fetch paths double the test surface and GitHub accepts fetch-by-sha.
- Decided: one Python stdlib dispatcher `scripts/grid`, because it needs JSON, SHA-256, argparse and subprocess; `wire.sh` stays bash.
- Decided: `grid.yaml` is read with `vetting`'s `scripts/lib/miniyaml.py`, not a second hand parser, because one restricted-YAML reader is enough and `vetting` merges first.
- Decided: `grid.lock` is JSON, because stdlib reads it everywhere and sorted keys diff cleanly.
- Decided: installed skills are placed at `repos/<source>/<path>` inside the uninitialised submodule dir, not in a separate store, because git ignores content there, and `wire.sh`, `catalog.sh`, the `vetting` allowlist paths and the `foundations` exclusions then work with no store logic.
- Decided: `grid` never writes into `repos/<source>` when `repos/<source>/.git` exists, because that is the maintainer path and must be unchanged.
- Decided: wired-set entries are typed by a `<kind>:` prefix and `grid` ignores every typed entry, because `rule-packs` (`rules:<pack>`) and `multi-harness` (`harness:<name>`) extend the baseline grammar and must not require a `grid` change or a version bump.
- Decided: lock and ledger entries carry `kind` and readers skip unknown kinds with a notice, because a later change can then lock upstream rule packs under `lockVersion` 1.
- Decided: `grid.yaml` reserves top-level `rules` and `harnesses` (ignored with a notice) and rejects other unknown keys, because typos must fail loudly while the two planned extensions stay non-breaking.
- Decided: the lock never records a harness, because placed files are harness-neutral and `wire.sh` decides where they are linked.
- Decided: `grid.yaml` lists only sources referenced by the tracked baseline, because library-tier repos are not installable and `docs/SOURCES.md` already indexes them.
- Decided: `wired.baseline` points at `baseline-submodules.example.txt`, because that is the tracked, shareable form of the grammar; personal baselines and overlays are never locked.
- Decided: the lock is generated by running `wire.sh` with `GRID_BASELINE` (introduced by `foundations#2`), because it reuses the grammar and precedence instead of reimplementing them.
- Decided: the lock run sets `GRID_HARNESS=claude`, `RULES_DIR` and `GRID_HARNESS_HOME` to temp values, because later changes make `wire.sh` link outside `SKILLS_DIR`.
- Decided: lock `sha` comes from the parent gitlink, and `grid lock` fails if a checkout is not at that commit or its skill dir is dirty, because the lock must describe committed state only.
- Decided: the lock stores `tree` as well as `hash`, because drift detection then needs trees only.
- Decided: the content hash covers tracked files plus an executable-bit class, because that is what `find_skill_mds` considers the skill and it avoids umask noise; on disk every file counts, so an added file is `modified`.
- Decided: `grid install` runs `audit.py` on the staged copy with `--root` at the staging run dir, because reported paths then match `repos/<source>/...` allowlist entries and nothing unvetted is ever placed.
- Decided: the install-time `audit.py` call does not pass `--baseline`, because the staging root has no `.gitmodules`; source curation is enforced on the install path by the step-1 `audit.py --check-url` call instead, and content rules still apply.
- Decided: audit failures are per entry (from the JSON `path`), not per source, because one bad skill must not block a whole upstream repo.
- Decided: `GRID_AUDIT=warn` is honoured; a missing `audit.py` or `policy.yaml` is exit 2 (`refusing to place unvetted content`) unless `GRID_AUDIT=warn`, which turns it into a loud skip (SEC13).
- Decided: `grid audit` is a pure passthrough to `scripts/audit.sh`, because `vetting` owns the interface.
- Decided: sources listed in `scripts/lib/runtimes.txt` (gstack) are skipped by `install` with a notice, because their skills need a built runtime from the full repo; the operator can init that one submodule, which `wire.sh` then prefers.
- Decided: `grid install` fetches every selected lock entry not denied by the machine's untyped deny lines, because resolving the full machine set needs files that do not exist yet; the cost is a few MB. Known limit: when an overlay denies the winning copy of a name that two sources provide, the losing source's copy is not in the lock and stays unwired on that machine.
- Decided: the ledger lives at `${GRID_STATE_DIR:-$HOME/.grid}/installed.manifest`, because machine-local state lives under `~/.grid/` (same variable `instincts` uses).
- Decided: ledger `dest` is relative to the grid dir, because it must survive moving the dir.
- Decided: `install`, `repair` and `uninstall` run `wire.sh` with the new `GRID_NO_CATALOG=1`, because a partial machine must not rewrite the tracked `SKILLS.md`; `GRID_SKIP_CATALOG` is not reused because it also suppresses `.wired.manifest` and the audit.
- Decided: `uninstall` is dry-run unless `--yes`, because it deletes files.
- Decided: `repair` never prunes without `--prune`, because `extra` entries may be intentional while a lock bump is in flight.
- Decided: drift exit code is 0 when the report is written, because scheduled jobs should not alarm on expected drift.
- Decided: drift reports go to `${GRID_STATE_DIR:-$HOME/.grid}/reports/`, because they are machine-local state.
- Decided: `grid schedule` only prints activation commands, because the repo never activates timers on the operator's behalf.
- Decided: weekly, Monday 09:00 local, because upstream churn does not justify daily.
- Decided: `project:` entries and composed agents are out of the lock, because their output is generated locally by `compose.py` and needs a venv.
- Decided: a `SKILL.md` that mentions `../` is a lock-time warning, not a failure, because the reference may be prose; the first real install shows whether any skill is broken.
- Decided: #37 is not touched here; `foundations#3` converts `.gitmodules` to HTTPS and this change depends on it.
- Decided: #6 is closed as folded without populating `agent-factory/skills/`, because the mapping is ambiguous and nothing needs it.
- Decided: #40 takes option 1 (drop `skills-factory`); only `README.md` (two lines), `automation-factory/README.md` and `project-factory/README.md` are edited.
- Decided: `grid.lock` and `grid.yaml` fields are validated against fixed patterns and `dest` is containment-checked before every write or delete, because the lock arrives through a PR and a crafted `path` must not write or delete outside `repos/<source>` or inject a git option.
- Decided: the content hash excludes `.DS_Store`, `__pycache__/` and `*.pyc` on both the git side and the disk side, because Finder and Python create them inside placed skill dirs and they would otherwise read as user edits.
- Decided: blob contents for the lock hash come from one `git cat-file --batch` per source and trees from `git ls-tree -r -z <sha>:<path>`, because `lock --check` runs in the commit gate and per-file processes are too slow, and `-z` is the only filename-safe form.
- Decided: a nested submodule (mode 160000) inside a wired skill is a lock-time error, because its content cannot be pinned by this hash.
- Decided: install and repair never overwrite a directory that differs from both the ledger and the lock (a user edit or a directory grid did not write) without `--force`; a directory that already matches the locked hash is adopted without a fetch, because grid owns only what it can prove it wrote.
- Decided: a replaced directory is moved into the staging dir, never to `<dest>.grid-old` beside it, because `find_skill_mds`'s plain-`find` fallback would wire a leftover `*.grid-old` as a skill after a crash.
- Decided: the verified staged directory is copied once with `shutil.copytree(symlinks=True)` into `<run>/place/<dest>`, re-checked for symlink escape and re-hashed there, and only then renamed into `<grid>/<dest>` (SEC15), because the bytes renamed into place must be the bytes just verified, outside the staged git worktree, with links never followed.
- Decided: `install` and `repair` take `--dry-run` (no network, no writes), because every mutating path in this repo's tooling has a plan mode.
- Decided: every git child gets `GIT_TERMINAL_PROMPT=0`, scrubbed `GIT_DIR`-family variables and a 600-second timeout, because the drift job runs unattended and a prompt or a hung fetch would block it forever.
- Decided: the staged repo sets `core.autocrlf=false` and `core.eol=lf`, because a user's global line-ending config would otherwise change bytes and fail verification.
- Decided: `grid` requires git 2.25 and checks it at start, and uses `init --cone` then `set` (not `set --cone`, which needs git 2.35), because Ubuntu 20.04 and 22.04 ship 2.25 and 2.34.
- Decided: the machine host key is `socket.gethostname().split(".")[0]`, not a call to `hostname -s`, because a minimal Arch or container install may lack the `hostname` binary.
- Decided: link ownership in `uninstall` and link selection in `lock` compare realpaths, and `GRID_DIR` handed to `wire.sh` is the realpath, because macOS temp and home paths go through symlinks and a string compare would silently match nothing.
- Decided: the `grid lock` child of `wire.sh` also gets `HOME=<tmp>/home` (but no `CLAUDE_CONFIG_DIR`; `GRID_DRY_HOME` forces it to `<tmp>/home/.claude`), because other changes make `wire.sh` maintain a user-settings hook entry and the lock run must write nothing real.
- Decided: `grid lock --check` exits 3 when a locked source is not checked out, and `gate.sh` treats 3 as a loud skip, because bash should not parse JSON to decide that.
- Decided: schedule files are rendered through `loops#3`'s `scripts/lib/render-schedule.sh` (weekly form), and only activation commands are printed (G2), because one renderer means one set of escaping rules and tests.
- Decided: `schedule install` refuses (exit 2) a grid path with characters outside `[A-Za-z0-9_./@+-]` (G2).
- Decided: the ledger is written even when some entries failed, and rows of an unknown `kind` are copied through verbatim, because the ledger must describe disk and a newer grid's rows must survive an older grid's rewrite.
- Decided: `scripts/grid` sets `sys.dont_write_bytecode` and the acceptance check for Python 3.8 syntax is an `ast.parse(..., feature_version=(3, 8))` call, not `py_compile`, because both would otherwise leave `__pycache__` in the repo.
- Decided: stale `.grid-tmp/*` entries older than a day are removed at start and `SIGTERM` runs the cleanup, because a scheduler kill must not leave staging dirs, and a leftover staged `SKILL.md` must not be discovered by any whole-tree `find`.
- Decided: gate integration is `grid lock --check`, skipped loudly when `python3` or `scripts/grid` is missing or the command exits 3 (a locked source is not checked out), because a stale lock must fail the commit.
- Decided: `grid` is invoked by path (`scripts/grid`); no PATH install or alias, because shell config is per-machine.
- Decided: the `grid lock` child of `wire.sh` also gets `GRID_DRY_HOME=<tmp>/home` (G1, `foundations#8`), so every home-derived target `wire.sh` knows about is redirected, in addition to the `HOME`/`CLAUDE_CONFIG_DIR` temp isolation.
- Decided: the sentinel host for the lock run is `GRID_HOST=__baseline__` (G5), replacing `lock-none`, so every dry-run caller in the repo uses one name.
- Decided: install and repair run `audit.py --check-url <url>` for each selected source before any network access, exit 2 on a disallowed source (warning under `GRID_AUDIT=warn`), and skip it with a notice for `file://` test sources (SEC13).
