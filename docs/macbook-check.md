# MacBook check: project kit on macOS

One-off check that the project kit (`cut-project.sh`, `retrofit.py`, `map.py` and their bats files) behaves on a Mac the same as on Linux (the authoritative platform, see `portability.md`). Target: `/bin/bash` 3.2.57, BSD userland, system python 3.9. Nothing here has been run on macOS yet; the expected values below come from a Linux run.

**Send results back by running every block with `| tee`**, so the output is saved to a file you can paste: blocks 1 to 3 end in `| tee ~/mac-check.txt` (append with `tee -a` after the first), block 4 writes `~/mac-check-smoke.txt`. Paste both files.

## 1. Pull, toolchain, global git config

```bash
cd ~/.the-grid && git pull --ff-only && git log -1 --format='%h %s'
git submodule update --init tests/lib/bats-core
export PATH=/usr/bin:/bin:/usr/sbin:/sbin:$PATH   # system bash/python3/git first, this shell only
{
  /bin/bash --version | head -1     # expect: GNU bash, version 3.2.57(1)-release (...apple-darwin...)
  which bash python3 git grep sed; python3 --version; git --version   # expect Python 3.9.x
  xcode-select -p                   # a path; if it errors, install the Command Line Tools first
  git config --global --get-regexp '^(commit\.gpgsign|core\.hookspath|init\.templatedir)$' || echo "no risky global git config"
  printf 'a\n' | grep -c 'a\|b'     # informational: 1 = BSD grep honours \|, 0 = it does not
  readlink -f / >/dev/null && echo "readlink -f ok"   # informational: fails on macOS < 12.3
} 2>&1 | tee ~/mac-check.txt
```

The project tests isolate git from your global config themselves; the git-config line is only for the record.

## 2. Targeted bats under the system bash

```bash
cd ~/.the-grid
for f in project_scaffold project_bootstrap project_retrofit project_factory charter_files map map_lint; do
  echo "##### $f"
  /bin/bash tests/lib/bats-core/bin/bats --tap tests/test_$f.bats > "/tmp/bats-$f.tap" 2>&1
  echo "exit=$? ok=$(grep -c '^ok' /tmp/bats-$f.tap) notok=$(grep -c '^not ok' /tmp/bats-$f.tap) skip=$(grep -c '# skip' /tmp/bats-$f.tap)"
  grep -A14 '^not ok' "/tmp/bats-$f.tap"
done 2>&1 | tee -a ~/mac-check.txt
```

Expected (Linux): `exit=0 notok=0` for every file, with `ok` counts

| file | ok |
|---|---|
| project_scaffold | 20 |
| project_bootstrap | 16 |
| project_retrofit | 63 |
| project_factory | 38 |
| charter_files | 38 (3 skips) |
| map | 39 |
| map_lint | 52 |

Skip counts may differ on the Mac (origin/main and case-sensitivity probes). A skip is fine, a `not ok` is not; the full `not ok` block is what to paste.

## 3. Gate-side checks

```bash
cd ~/.the-grid
{ bash scripts/check-personal.sh; echo "rc=$?"; python3 scripts/map.py --check; echo "rc=$?"; } 2>&1 | tee -a ~/mac-check.txt
```

Expected: `personal: 0 finding(s)` with `rc=0` (no private denylist on this Mac is fine), then no output and `rc=0`.

## 4. Manual smoke

`project-factory/scripts/mac-smoke.sh` scaffolds, reruns, hits a differing file, cuts `--grid`, cuts into a Finder-style folder, then runs a retrofit end to end. It writes only under a temp dir (removed on exit), and points `HOME` and git config at that dir.

```bash
cd ~/.the-grid
bash project-factory/scripts/mac-smoke.sh 2>&1 | tee ~/mac-check-smoke.txt
```

Paths and the order of `wrote:` lines differ by OS; counts must match.

| step | expected |
|---|---|
| probe | informational: 1 on default APFS (case-insensitive), 2 on Linux |
| S1 | `Mode: seed`, 10 `wrote:` lines, `git init'd`, `Done. 10 file(s) written, 0 skipped.`, rc=0 |
| S1b | `map.py: knowledge lint skipped (knowledge.py not found next to map.py)`, rc=0 |
| S2 | `Mode: retrofit`, `unchanged: 9 file(s)`, `Done. 0 file(s) written, 0 skipped.`, rc=0 |
| S3 | `SKIPPED (exists, differs ...): CONVENTIONS.md`, `Done. 9 file(s) written, 1 skipped.`, content stays `mine` |
| S4 | `Mode: seed`, `set core.hooksPath=.githooks`, `Done. 30 file(s) written, 0 skipped.`, `map --check rc=0` |
| S4b | `.DS_Store` plus `._x` only: `Mode: seed` and `git init'd` |
| S4c | `.DS_Store` plus a real file: `Mode: retrofit`, no `git init` |
| S5 | see below |

S5 (retrofit), same bytes must give the same hashes as Linux:

- survey: `CLAUDE.md 103 bytes 7 blocks`
- header: `## source: CLAUDE.md sha256:48e0285cde2db9ac03a71bf5a82d89db147c0d2a01448f862b5ad3ac64b53484`
- block ids: `B001-4320 B002-d3e5 B003-0947 B004-044d B005-6991 B006-f9b7 B007-aa3c` (a mismatch means python 3.9 vs 3.12 or newline handling differs)
- apply dry run rc=0; `apply --yes` `wrote 3 file(s)`; again `wrote 0 file(s)` and four `skip (already applied)`
- `check`: `accounted: 7/7   missing or altered: 0`, rc=0
- `finalize` dry run and `--yes`: rc=0, with an undo `mv 'docs/archive/CLAUDE.md.<date>.orig' 'CLAUDE.md'`
- `check` after finalize: `accounted: 7/7`, rc=0, and `ls docs/archive` shows one `.orig`

## 5. Optional repeat with your default PATH

If Homebrew bash or python3 is installed, rerun blocks 2 to 4 without the `export PATH=...` line. A failure in only one toolchain is itself the finding.

## Known, not blocking

- Cosmetic only: BSD `wc` pads counts with spaces in two echo lines; bare `mktemp -d` returns `/var/...` (not canonical) in some tests that never compare it.
- `scripts/knowledge.py` hashes claims with the Unicode tables of the local python (13 on macOS 3.9, 15 on 3.12): ASCII claims are identical, exotic characters may hash differently across machines.
- A project that already has `Claude.md` beside `CLAUDE.md` on a case-insensitive disk can confuse `map.py`; none of the checks above create that case.
