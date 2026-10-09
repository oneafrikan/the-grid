## Context

- Today: submodules under `repos/` plus `scripts/wire.sh` symlinking skills into the skills dir. Wired set = `baseline-submodules.txt` + `machines/<host>.txt` + `machines/<host>.local.txt` (all gitignored; seeded from `baseline-submodules.example.txt` and `machines/example.txt`).
- `wire.sh` already writes `.wired.manifest` (TSV: kind, name, target, status, reason; sorted; no timestamp; rewritten only when changed), has `--check`, and `GRID_SKIP_CATALOG=1` (skips both the `.wired.manifest` write and the `SKILLS.md` refresh; `vetting` also skips its audit under it).
- `scripts/lib/find-skill-mds.sh` lists tracked `SKILL.md` files in a git checkout and falls back to plain `find` in a directory that is not its own checkout (an uninitialised submodule dir). `foundations#1` adds exclusions to both branches.
- An uninitialised submodule dir `repos/<n>` is an empty directory tracked as a gitlink. Verified with git 2.39: files placed inside it do not appear in `git status`, `git add -A` ignores them, and `git add <file>` refuses ("Pathspec is in submodule"). `git submodule update --init repos/<n>` refuses a non-empty dir with a clear error and changes nothing.
- Prior art (ideas, not code): ECC's install-state (`doctor` diffs disk against recorded operations, `uninstall` deletes only recorded operations); Microsoft APM's manifest plus lock with content hashes. Claude Code marketplace entries pin sources with a 40-char `sha`; the lock uses the same pin shape so `plugin-marketplace` can reuse it later.
- Cross-change inputs this change consumes (none are re-introduced here):
  - `foundations#2`: `GRID_BASELINE` (path override for the baseline manifest in `wire.sh`).
  - `foundations#3`: `.gitmodules` URLs are HTTPS.
  - `foundations#5`: `scripts/lib/runtimes.txt` (pipe-separated, first field = repo name).
  - `vetting#1`: `scripts/lib/miniyaml.py` (`loads(text)`, `ParseError(line, msg)`), `scripts/audit.py`, `policy.yaml`.
  - `vetting#3`: `scripts/audit.sh --owned|--wired|--gate`.
  - `loops#3`: `scripts/lib/render-schedule.sh` (`render_launchd_plist`, `render_systemd_service`, `render_systemd_timer`, `render_crontab_line`; arguments documented in that file's header).
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

- In every file of the wired set (`wired.baseline`, `machines/<host>.txt`, `machines/<host>.local.txt`), an entry whose text before the first `/` contains `:` is a typed entry: `<kind>:<value>` or `-<kind>:<value>`. Known kinds today: `project`; added by later changes: `rules`, `harness`.
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

Content hash: list every tracked file under `<path>` at `sha` (`git ls-tree -r <sha> -- <path>`), sort by repo-relative path bytes, then SHA-256 over the concatenation of lines `<class> <relpath> <sha256-of-content>\n`, where class is `x` (mode 100755), `-` (100644) or `l` (120000; content = the link target string). Prefix `sha256:`. On disk (install, doctor) the same lines are computed from the directory: class `l` if `os.path.islink`, else `x` if any execute bit is set, else `-`; every file under the dir is included (so an added file changes the hash). A symlink whose target resolves outside the skill dir is a hard error at lock time (exit 2).

Ledger `${GRID_STATE_DIR:-$HOME/.grid}/installed.manifest` (machine-local; TSV; sorted `LC_ALL=C`; no timestamp; written atomically via temp file plus `os.replace`, and only when content changes). Columns: `kind`, `name`, `source`, `sha`, `path`, `dest`, `hash`. `dest` is relative to the grid dir (`repos/<source>/<path>`).

```
skill	docx	anthropic	53048666b05b4799081517d00e09e0a2dd688678	skills/docx	repos/anthropic/skills/docx	sha256:9f2c...
```

- One installed grid per user account: the ledger describes the grid dir `grid` is run against. `doctor` against a different clone reports its rows `absent`; `uninstall` containment (below) keeps a mismatch harmless.
- Relationship to `.wired.manifest`: that file stays exactly as `wire.sh` writes it (what is linked where). The ledger says what `grid` placed. `doctor` joins them by `dest`.

### Fetch mechanism

One staging run dir per invocation: `<grid>/.grid-tmp/<pid>/` (gitignored), removed in a `finally`. Per source:

```
git init -q <run>/repos/<source>
git -C <run>/repos/<source> remote add origin <url>
git -C <run>/repos/<source> fetch -q --depth 1 --filter=blob:none origin <sha>
git -C <run>/repos/<source> sparse-checkout init --cone
git -C <run>/repos/<source> sparse-checkout set <path> <path> ...
git -C <run>/repos/<source> checkout -q FETCH_HEAD
```

- Verify `rev-parse HEAD` equals the locked `sha`, `rev-parse HEAD:<path>` equals `tree`, and the on-disk content hash of `<run>/repos/<source>/<path>` equals `hash`. A mismatch fails that entry.
- When `GRID_TRACE_FETCH` is set, append one line `<source> <sha>` to that file per fetch (tests use it to prove a no-op re-run).

### Vetting the staged copy

- After verification, one call per source: `python3 <grid>/scripts/audit.py --format json --root <run> --grid-dir <grid> <run>/repos/<source>/<path> ...` (every verified path of that source). Reported paths therefore read `repos/<source>/...`, so `CURATION.md` allowlist entries written for the maintainer path match.
- Exit 0: all paths pass. Exit 1: parse the JSON; an entry fails when any finding has `severity: "high"`, `allowed: false` and a `path` starting with `repos/<source>/<entry path>/`; other entries of the source pass. Exit 2 or unparseable output: every entry of that source fails.
- `GRID_AUDIT=warn` (same variable `vetting` gives `wire.sh`): failing entries are placed anyway with a stderr warning naming them.
- No `scripts/audit.py` or no `policy.yaml` in the grid dir: print `grid: audit SKIPPED (no audit.py/policy.yaml) - placed unvetted` to stderr and continue.
- `grid audit [args...]` runs `bash <grid>/scripts/audit.sh args...` with the same environment and returns its exit code. No other logic.

### Install algorithm

1. Read `grid.yaml` and `grid.lock`; refuse (exit 2, before any network) any source URL not `https://` (`file://` allowed only when `GRID_ALLOW_FILE=1`, for tests).
2. Seed `baseline-submodules.txt` from `baseline-submodules.example.txt` and `machines/<host>.txt` from `machines/example.txt` if absent (host = `GRID_HOST`, else `hostname -s`; same as `bootstrap.sh`).
3. Select `kind: skill` lock entries, minus untyped deny lines (`-source`, `-source/skill` matched against `source` and the basename of `path`) found in the baseline and both overlays. Typed lines are ignored.
4. Drop entries whose source is listed in `scripts/lib/runtimes.txt` (first `|` field, trimmed; absent file = none) and print once per source: `grid: <source> needs a runtime; use the maintainer path for it: git submodule update --init repos/<source> && bash scripts/runtime-setup.sh <source>`.
5. Drop entries whose `repos/<source>/.git` exists (maintainer checkout) and print once per source `grid: <source> is a submodule checkout; left to the maintainer path`.
6. Skip an entry already in the ledger with the locked `sha` and `hash` whose `dest` exists and re-hashes to `hash` (re-run is a no-op, no fetch).
7. Group the rest by source; fetch, verify, audit; place each passing entry: copy the staged dir (no `.git`) to `<grid>/.grid-tmp/<pid>/place/<dest>`, then if `dest` exists rename it to `<dest>.grid-old`, rename the new dir into place, delete `<dest>.grid-old`. Create missing parents under `repos/<source>/`.
8. Remove dirs that are in the old ledger but no longer selected (same containment rules as `uninstall`).
9. Write the ledger (selected and placed entries only).
10. Run `GRID_NO_CATALOG=1 bash <grid>/scripts/wire.sh` (env `GRID_DIR`, `SKILLS_DIR`, `AGENTS_DIR`, `GRID_HOST` passed through). A non-zero exit from it is reported and makes `install` exit 1.
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
- `grid repair [--prune]` re-fetches only `missing`, `stale`, `absent`, `modified` entries at the locked sha (same fetch, verify, audit and place), rewrites the ledger, runs `wire.sh` as in install step 10. `extra` entries are removed only with `--prune`.
- `grid uninstall [--yes] [--force]` prints the plan (ledger dirs, links in `SKILLS_DIR` whose `readlink` equals `<grid>/<dest>` of a ledger row, the ledger file) and changes nothing without `--yes`. Containment for every deletion: `os.path.realpath(<grid>/<dest>)` must lie under `realpath(<grid>/repos/<source>)` (via `os.path.commonpath`), `repos/<source>/.git` must not exist, and the dir itself must not be a symlink (`os.lstat`). A dir whose on-disk hash differs from the ledger is skipped and listed unless `--force`. After removing a dir, remove now-empty parents up to but not including `repos/<source>`. Never touches `.git` dirs, `baseline-submodules.txt`, `machines/*`, foreign links or real dirs in `SKILLS_DIR`. A second run reports `nothing to remove` and exits 0.

### Drift report

- Per distinct source in the lock: `git ls-remote <url> <ref or HEAD>`. Equal to the locked sha: all its entries `unchanged`, no fetch.
- Different: into a temp bare repo under `.grid-tmp/<pid>/`, `git fetch --depth 1 --filter=blob:none origin <head>` (trees only), then per entry compare `rev-parse FETCH_HEAD:<path>` with the lock `tree`: `unchanged`, `changed`, or `removed` (path gone). `ls-remote` or fetch failure: the source is `unreachable`.
- Report: Markdown, written to `${GRID_STATE_DIR:-$HOME/.grid}/reports/drift-YYYY-MM-DD.md` (UTC date) and copied to `drift-latest.md` in the same dir. Contents: counts per class, then changed and removed entries grouped by source with short locked and upstream shas, then unreachable sources. No absolute paths, no hostname.
- Exit 0 whenever the report was written (a schedule must not alarm on expected drift); exit 2 on a tool failure. `--quiet` suppresses stdout. `grid.lock`, the ledger and every `repos/` dir are untouched.
- Maintainer response is manual: `git submodule update --remote repos/<n>`, `grid lock`, review, PR.

### Schedule

`grid schedule install|remove`. Opt-in only; `grid install` never schedules anything. Units are rendered by calling `bash -c 'source "$0"; <function> "$@"' <grid>/scripts/lib/render-schedule.sh <args>` with the arguments that file's header documents. Nothing is activated: the activation command is printed.

| OS (`GRID_OS` override, else `uname -s`; Linux counts as systemd when `systemctl --user show-environment` succeeds or `GRID_OS=Linux`) | Files written | Printed command |
|---|---|---|
| `Darwin` | `${LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}/io.the-grid.drift.plist`, weekly Monday 09:00 local | `launchctl bootstrap gui/$(id -u) <plist>` |
| `Linux` (systemd user) | `${SYSTEMD_USER_DIR:-$HOME/.config/systemd/user}/grid-drift.service` and `grid-drift.timer`, `OnCalendar=Mon *-*-* 09:00:00`, `Persistent=true` | `systemctl --user daemon-reload && systemctl --user enable --now grid-drift.timer`, plus the `loginctl enable-linger "$USER"` note |
| anything else | none | the crontab line `0 9 * * 1 <abs grid> drift --quiet # the-grid drift` |

- The job command is `<absolute path of scripts/grid> drift --quiet`, resolved at run time and written only into the generated local file.
- `install` writes byte-identical files on a second run. `remove` deletes exactly those files (or prints the crontab line to delete) and prints the deactivation command.

### CLI shape

`scripts/grid`: one Python 3 stdlib file (plus `scripts/lib/miniyaml.py` via `sys.path` from `__file__`, as `audit.py` does), `argparse` subcommands, Python 3.8+. Exit codes: 0 ok, 1 findings or failed entries, 2 usage or error. Shared flags: `--grid-dir` (else `GRID_DIR`, else parent of `scripts/`), `--skills-dir` (else `SKILLS_DIR`). Environment: `GRID_DIR`, `SKILLS_DIR`, `AGENTS_DIR`, `GRID_HOST`, `GRID_STATE_DIR`, `GRID_ALLOW_FILE`, `GRID_TRACE_FETCH`, `GRID_AUDIT`, `GRID_OS`, `LAUNCH_AGENTS_DIR`, `SYSTEMD_USER_DIR`. Every child process runs with `LC_ALL=C`.

### grid lock

- Runs `wire.sh` with `GRID_SKIP_CATALOG=1 GRID_SKIP_AUDIT=1 GRID_BASELINE=<grid>/<wired.baseline> GRID_HOST=lock-none GRID_HARNESS=claude SKILLS_DIR=<tmp>/skills AGENTS_DIR=<tmp>/agents RULES_DIR=<tmp>/rules GRID_HARNESS_HOME=<tmp>/home` (variables a later change has not introduced yet are harmless), so lock and wire can never read the baseline differently and nothing outside the temp dir is written.
- Takes every symlink in `<tmp>/skills` whose target is `<grid>/repos/<source>/<path>` with a non-empty `path` and a `SKILL.md` in the target (this excludes the `foundations` runtime-root link).
- `sha` from `git ls-files -s repos/<source>`; exit 2 naming the source if `git -C repos/<source> rev-parse HEAD` differs or `git -C repos/<source> status --porcelain -- <path>` is non-empty. Writes `grid.lock` atomically.
- Warns on stderr (never fails) when a `SKILL.md` contains `../`.
- `grid lock --check` regenerates in memory, exits 1 listing added, removed and changed entries, and also runs doctor check 1 plus "every untyped baseline repo has a `sources` entry".

### #6 (agent-factory/skills/)

Parked because the candidate mapping is ambiguous and `wire.sh` already gives subagents ecosystem skills. Nothing here makes it more necessary, and installed skills sit at the same `repos/<source>/<path>` as on the maintainer path, so any future resolve-by-name works on both. Closed as folded with that note.

### #40 (skills-factory/)

The directory has no tracked files, so nothing is deleted in git. Public docs are edited so none names it. `index.html` copy is left to `front-door`.

### Tests

- New bats files: `test_grid_manifest.bats`, `test_grid_lock.bats`, `test_grid_install.bats`, `test_grid_health.bats`, `test_grid_drift.bats`, `test_docs_factories.bats`; shared builder `tests/helpers/grid_fixture.bash`.
- Fixture: a throwaway upstream git repo built in the test with `git config uploadpack.allowFilter true` and `uploadpack.allowAnySHA1InWant true`, referenced as `file://` with `GRID_ALLOW_FILE=1`; a fixture grid dir with `repos/<src>` as an empty dir, copies of `scripts/wire.sh`, `scripts/lib/find-skill-mds.sh`, `scripts/lib/miniyaml.py`, `scripts/grid`; `GRID_DIR`, `SKILLS_DIR`, `AGENTS_DIR`, `GRID_STATE_DIR`, `LAUNCH_AGENTS_DIR`, `SYSTEMD_USER_DIR` all under `mktemp -d` (plus `common_setup`). Git file-protocol fetches need `-c protocol.file.allow=always`; `scripts/grid` passes it only when `GRID_ALLOW_FILE=1`.
- No test touches the network, real `~/.grid`, or runs `launchctl`/`systemctl`/`crontab`.

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
- Decided: the install-time `audit.py` call does not pass `--baseline`, because the staging root has no `.gitmodules` and source curation is already enforced by the `vetting` gate before a lock is committed; content rules still apply.
- Decided: audit failures are per entry (from the JSON `path`), not per source, because one bad skill must not block a whole upstream repo.
- Decided: `GRID_AUDIT=warn` is honoured and a missing scanner is a loud skip, matching the `vetting` behaviour of `wire.sh`.
- Decided: `grid audit` is a pure passthrough to `scripts/audit.sh`, because `vetting` owns the interface.
- Decided: sources listed in `scripts/lib/runtimes.txt` (gstack) are skipped by `install` with a notice, because their skills need a built runtime from the full repo; the operator can init that one submodule, which `wire.sh` then prefers.
- Decided: `grid install` fetches every selected lock entry not denied by the machine's untyped deny lines, because resolving the full machine set needs files that do not exist yet; the cost is a few MB.
- Decided: the ledger lives at `${GRID_STATE_DIR:-$HOME/.grid}/installed.manifest`, because machine-local state lives under `~/.grid/` (same variable `instincts` uses).
- Decided: ledger `dest` is relative to the grid dir, because it must survive moving the dir.
- Decided: `install`, `repair` and `uninstall` run `wire.sh` with the new `GRID_NO_CATALOG=1`, because a partial machine must not rewrite the tracked `SKILLS.md`; `GRID_SKIP_CATALOG` is not reused because it also suppresses `.wired.manifest` and the audit.
- Decided: `uninstall` is dry-run unless `--yes`, because it deletes files.
- Decided: `repair` never prunes without `--prune`, because `extra` entries may be intentional while a lock bump is in flight.
- Decided: drift exit code is 0 when the report is written, because scheduled jobs should not alarm on expected drift.
- Decided: drift reports go to `${GRID_STATE_DIR:-$HOME/.grid}/reports/`, because they are machine-local state.
- Decided: `grid schedule` renders with `loops`' `scripts/lib/render-schedule.sh` and only prints activation commands, because one renderer serves the repo and the repo never activates timers on the operator's behalf.
- Decided: weekly, Monday 09:00 local, because upstream churn does not justify daily.
- Decided: `project:` entries and composed agents are out of the lock, because their output is generated locally by `compose.py` and needs a venv.
- Decided: a `SKILL.md` that mentions `../` is a lock-time warning, not a failure, because the reference may be prose; the first real install shows whether any skill is broken.
- Decided: #37 is not touched here; `foundations#3` converts `.gitmodules` to HTTPS and this change depends on it.
- Decided: #6 is closed as folded without populating `agent-factory/skills/`, because the mapping is ambiguous and nothing needs it.
- Decided: #40 takes option 1 (drop `skills-factory`); only `README.md` (two lines), `automation-factory/README.md` and `project-factory/README.md` are edited.
- Decided: gate integration is `grid lock --check`, skipped loudly when `python3` or `scripts/grid` is missing or any locked submodule is uninitialised, because a stale lock must fail the commit.
- Decided: `grid` is invoked by path (`scripts/grid`); no PATH install or alias, because shell config is per-machine.
