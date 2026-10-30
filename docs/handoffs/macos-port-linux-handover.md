# Handover: macOS port (PR #301) for a Linux session

KEPT as a record (operator decision, 2026-10-30). It was written for the Linux session that verified branch `fix/macos-bats` (PR #301) and stays after the merge as the account of what the macOS port changed and how it was checked. Sections 3 to 5 and 10 are the one-time verification and merge steps; they are done once the PR is merged.

Audience: a Claude or human session on a Linux box that has just checked out `fix/macos-bats` and has its own in-flight branch that was never run on macOS.

Rules for writing new shell/tests afterwards: `docs/portability.md`. Read it before Step C.

## 1. Goal

Make the bats suite and the hook guards pass on macOS (/bin/bash 3.2.57, BSD userland, python 3.9.6, no GNU `timeout`, case-insensitive APFS, `/var` -> `/private/var`) without changing behaviour on Linux. Linux CI is authoritative.

State at hand-off:
- macOS full suite: 194 failures -> 1 (plan `1..3560`, 3559 ok incl. 33 skips); the 1 left (a personal-data finding in a test comment) was then fixed. RAN on the author's Mac.
- UNTESTED: Linux, bash 4/5, shellcheck (none available on the author's Mac). Every claim below that says "safe on GNU" is READ from the diff, not run.
- All commits used `GRID_SKIP_HOOK=1` (the pre-commit hook runs the whole gate, which was red on macOS for the causes fixed here).

## 2. What changed

Verify any line with `git diff main..fix/macos-bats -- <file>`.

### Product code (affects real behaviour: review first)

- `hooks/lib/common.sh`: new `_grid_count_tokens` (sets `_GCT`) and `_grid_unquote` (sets `_GUQ`); both work on 256-byte slices (the `${s//pat/}` form is quadratic on bash 3.2: a 14 KB command took 25 to 70 s, past the 5 s hook timeout, and a timed-out hook does not block). `grid_check_cmd_cap` and `grid_check_balanced` call them. GNU: same output by construction (one-char class; a slice end moves +1 so a backslash-newline pair is never split). Needs the differential in 4.10.
- `hooks/lib/common.sh`, guard fix: backslash-newline pattern is now `${c//\\$'\n'/}`. The old `${c//$'\\\n'/}` did not match on bash 3.2.57, so `g\<NL>it commit -n` was not blocked. Security-sensitive: bash 4/5 must still match (check in 4.10).
- `hooks/scripts/pre-bash-no-bypass.sh`, `hooks/scripts/pre-bash-secret-scan.sh`: call `_grid_unquote` instead of the two inline `${//}` lines. Same result on GNU (differential).
- `scripts/catalog.sh`: `--check` temp file uses `mktemp "${TMPDIR:-/tmp}/catalog.XXXXXX"` (GNU honours TMPDIR either way: same dir); baseline read via `exec 4< file || exit 1` then `done <&4` so the EXIT trap runs and `--check` exits 2 for an unreadable baseline (bash 3.2 exited 1 without the trap). GNU: same behaviour, descriptor 4 is closed after the loop.
- `scripts/lib/miniyaml.py`: bare integer scalar over 4300 digits raises `ParseError` ("integer too long"). Python 3.11+ already refuses such an `int()`; the new check gives 3.9 the same answer. Boundary already RAN on python 3.9.6 (4299 and 4300 parse, 4301 raises); repeat on Linux python (4.7).
- `hooks/lib/auto-handoff-worker.sh`: `DIGEST_DIR` / `SNAP_DIR` use `mktemp -d "${TMPDIR:-/tmp}/tmp.XXXXXXXXXX"` (BSD ignores TMPDIR for a bare `mktemp -d`; GNU: same dir as before).
- `scripts/instincts/inject.py`, `agent-factory/run_evals.py`: `from __future__ import annotations` so `X | None` hints do not evaluate on python 3.9. No-op on 3.10+.

### Test infrastructure (test-only)

- `tests/helpers/setup.bash`: `mktemp_canon` (canonical `mktemp -d`, used by `common_setup`; on Linux `/tmp` is already canonical so identical); `ensure_timeout` (called first in `common_setup`; returns at once when a real `timeout` is on PATH, otherwise symlinks `gtimeout` or writes a perl shim under `BATS_FILE_TMPDIR`); `path_without`: dropped `local IFS=:`.
- `tests/test_issue_loop_runner.bats`: `use_real_timeout` fix (puts the real `timeout` ahead of the stub; see its comment).
- `tests/helpers/portable.bash` (new, `load helpers/portable`): `file_mode` (GNU `stat -c %a` first, BSD `stat -f %Lp` fallback); `sed_i` (`sed -i.bak` then remove the `.bak`; valid on GNU and BSD).
- `tests/test_repo_health.bats`: skips an EMPTY `repos/*` dir that is not in `baseline-submodules.example.txt`. A baseline repo must still be present. On CI all submodules are initialised, so the skip never fires.
- `tests/test_knowledge_sweep.bats`: `coproc` replaced by a python `flock` holder + `mkfifo`; `stat -c %s` -> `wc -c | tr -d " "`; `cmp -n` -> `cmp` against `head -c` prefix.
- `tests/test_plugins.bats`: hostname leak check uses `grep -rlE` (the `-P` form with `\Q..\E` is gone: BSD grep has no `-P`); skipped when the host is literally `daily` (an English word in shipped prose); still runs for every other host.
- `tests/test_hooks.bats`: `_fill` skips a zero count (`head -c 0` fails on BSD); NBSP expectation is probed and skipped where libc treats NBSP as `[[:space:]]` (macOS); the deadline test uses `SECRET_DEADLINE_US=0` (no `EPOCHREALTIME` on 3.2).
- `tests/test_auto_handoff.bats`, `test_rules.bats`: case-only renames via a temp name (APFS); leak check only counts temp dirs holding the worker's own files (`fs.before`, `git0.state`); `sed_i`.
- `tests/test_instincts_capture.bats`: canonical `PROJ` (`pwd -P`); `file_payload` builds JSON in python (bash 3.2 mangles inline quoted JSON in `"$(...)"`); `file_mode`.
- `tests/test_harness_rules.bats`: `$'\t'`-based `grep -E` instead of `-P`; `sed_i`.
- Mechanical (`mktemp_canon`, `sed_i`, `file_mode`, `grep -E`): `test_audit`, `test_audit_integration`, `test_budget`, `test_charter_files`, `test_contexts`, `test_deploy_hooks`, `test_grid_install`, `test_harness_formats`, `test_instincts_lib`, `test_instincts_register`, `test_issue_loop_hooks`, `test_issue_loop_runner`, `test_pages_site`.

## 3. STEP A: verify the branch on Linux

Goal: prove #301 is green on GNU/bash 4-5 before it merges.

```bash
cd ~/.the-grid                     # or wherever the repo is checked out
git fetch origin
git worktree list                  # report and prune stale entries (repo rule)
git worktree prune
git status --short                 # park your own work first; this step needs a clean tree
git branch --show-current          # note your own in-flight branch to return to in Step C
git checkout fix/macos-bats && git pull --ff-only
gh pr view 301 --json state,mergeable,statusCheckRollup --jq '{state,mergeable}'
git submodule update --init --recursive
bash scripts/gate.sh               # shellcheck, catalog, role lint, compose, check-personal, bats
```

- Shellcheck has never run on the changed shell files (`hooks/lib/common.sh`, `hooks/lib/auto-handoff-worker.sh`, `hooks/scripts/pre-bash-*.sh`, `scripts/catalog.sh`, `tests/helpers/*.bash` if linted). The first run here is the first run anywhere.
- To run only the suite, in the background (10+ minutes; do not poll, wait for the exit notification):

```bash
tests/lib/bats-core/bin/bats tests/ > /tmp/bats-linux.log 2>&1; echo "exit=$?" >> /tmp/bats-linux.log
tail -5 /tmp/bats-linux.log
grep -E '^not ok' /tmp/bats-linux.log
```

Green looks like: gate prints `gate: PASS` (skips are only those CI names: `plugins-validate`, `personal-denylist`, composed projects when uncomposed); bats ends with `1..N` and no `not ok` lines (skips are fine; expect fewer skips than macOS since the NBSP probe does not skip on glibc).

If something fails, it is a bug in this PR on Linux:
1. Fix it on `fix/macos-bats` in a small commit (one fix per commit).
2. Keep the macOS behaviour working: GNU form first or a probe, never delete the BSD fallback.
3. Do not weaken or delete a test to get green. If a test is genuinely platform-specific, probe and skip with a reason (`docs/portability.md`, "When a test is genuinely platform-specific").
4. `hooks/lib/common.sh` and `hooks/scripts/pre-bash-*.sh` are security guards: a fix must keep `g\<NL>it commit -n`, `g""it`, and `g\it` blocked. Get a second review.
5. Re-run just the failing file: `tests/lib/bats-core/bin/bats tests/test_<name>.bats`, then the whole suite again before pushing.
6. The pre-commit hook now runs on your new commits and the gate should pass on Linux. Do not use `GRID_SKIP_HOOK=1` unless the gate is red for a reason you can name.

## 4. Risk checklist (nobody ran these on Linux)

Tick each as RAN with the command, or file a failure.

1. [ ] `ensure_timeout` no-op: `bash -c 'command -v timeout'` finds GNU timeout, so `ensure_timeout` returns before creating anything. Check: after a bats run, `ls "$BATS_FILE_TMPDIR/timeout-shim"` must not exist (add a temporary `echo` if needed). A shim shadowing the real `timeout` would change exit-code behaviour (GNU 124 vs shim 124 is the same, but `-s`/`--foreground` handling differs).
2. [ ] `file_mode` GNU-first: `source tests/helpers/portable.bash; file_mode /etc/passwd` prints `644`.
3. [ ] `sed_i` `-i.bak`: `cd "$(mktemp -d)"; printf 'a\n' > f; source <repo>/tests/helpers/portable.bash; sed_i 's/a/b/' f; cat f; ls` shows `b` and only `f` (no `f.bak`).
4. [ ] `grep -E` replacements for `-P`: `tests/test_harness_rules.bats`, `tests/test_plugins.bats` pass. The plugins host regex lost `\Q..\E`: `host` is now interpolated into an ERE, so a hostname with `.` or other regex metacharacters matches more loosely than before (looser = may false-positive, never misses a leak). Check `hostname -s` on this box; if it contains a dot-free alnum name it behaves the same. Also confirm the `[^[:alnum:]_-]` boundary rejects `host-a-b` as GNU `(?<![\w-])` did.
5. [ ] `exec 4<` in `scripts/catalog.sh`: `bash scripts/catalog.sh --check; echo $?` is 0 on a clean tree; with an unreadable baseline (`GRID_BASELINE=/nonexistent bash scripts/catalog.sh --check` and a chmod 000 copy) exit is 2, no stray temp file left under `${TMPDIR:-/tmp}/catalog.*`. Confirm fd 4 is not used elsewhere in the script (`grep -n '4<\|<&4\|>&4' scripts/catalog.sh`).
6. [ ] Worker mktemp template: `tests/test_auto_handoff.bats` passes; run with `TMPDIR=$(mktemp -d)` and confirm no `tmp.*` dir leaks outside it.
7. [ ] miniyaml limit vs 3.11+ built-in limit: Python 3.11+ already raises at 4300 digits inside `int()`. The new check uses `len(s.lstrip("+-")) > 4300`. Boundary: 4300 digits parses, 4301 raises `ParseError`, on this box's python:
   ```bash
   python3 - <<'PY'
   import sys; sys.path.insert(0, "scripts/lib")
   import miniyaml
   for n in (4299, 4300, 4301):
       try: miniyaml.loads("k: " + "1" * n); print(n, "ok")
       except Exception as e: print(n, type(e).__name__, e)
   PY
   ```
   Expect 4299 and 4300 ok, 4301 ParseError. Check no existing test relied on the old 3.11 `ValueError` path with a different message.
8. [ ] Python flock holder in `tests/test_knowledge_sweep.bats`: runs on Linux, leaves no `holder.fifo` and no `python3 -I -c ... flock` process (`pgrep -fl 'fcntl,sys,time'` empty after the file).
9. [ ] Skip logic: `tests/lib/bats-core/bin/bats tests/test_hooks.bats tests/test_plugins.bats tests/test_repo_health.bats tests/test_rules.bats` and list skips (`grep -c 'skip'` in the output). Required on Linux: NBSP test RUNS (not skipped); plugins hostname check RUNS unless this box is literally named `daily`; repo_health skip does not fire with submodules initialised; the rules.bats `readme.md`-beside-`README.md` half RUNS (case-sensitive FS).
10. [ ] `_grid_unquote` / `_grid_count_tokens` under bash 4/5, differential against the old form. Run this in a scratch dir; it never touches the repo:
```bash
d="$(mktemp -d)"; cd ~/.the-grid
# Old and new definitions, extracted from git, in separate files.
git show main:hooks/lib/common.sh > "$d/old.sh"
cp hooks/lib/common.sh "$d/new.sh"
cat > "$d/diff.sh" <<'SH'
#!/usr/bin/env bash
# ref: the unsliced inline form with the CORRECT backslash-newline pattern. It is the oracle for
# the slicing logic and is valid on any bash.
old_unquote() { local t="${1//\\$'\n'/}"; t="${t//[\"\'\\]/}"; printf '%s' "$t"; }
# main's original pattern ($'\\\n'), informational only: it does not match backslash-newline on bash 3.2,
# so a diff against it on 3.2 is the bug this PR fixed, not a failure. On bash 4/5 it should agree.
main_unquote() { local t="${1//$'\\\n'/}"; t="${t//[\"\'\\]/}"; printf '%s' "$t"; }
old_count()   { local t="${1//[^[:space:];&|()\`]/}"; printf '%s' "${#t}"; }
source "$1"   # new.sh: defines _grid_unquote (sets _GUQ), _grid_count_tokens (sets _GCT)
fail=0
check() {  # check <label> <input>
  local o n
  o="$(old_unquote "$2")"; _grid_unquote "$2"; n="$_GUQ"
  [ "$o" = "$n" ] || { echo "UNQUOTE DIFF: $1 (${#2} bytes)"; fail=1; }
  [ "$(main_unquote "$2")" = "$n" ] || echo "info: differs from main's original pattern: $1"  # bash 4/5: should not print
  o="$(old_count "$2")"; _grid_count_tokens "$2"
  [ "$o" = "$_GCT" ] || { echo "COUNT DIFF: $1 old=$o new=$_GCT"; fail=1; }
}
NL=$'\n'
rep() { local s="" i; for ((i=0;i<$2;i++)); do s+="$1"; done; printf '%s' "$s"; }
# slice edges: 254-258, 509-514, 767-769 bytes, plain and with a quote / backslash-newline at the edge
for n in 254 255 256 257 258 509 510 511 512 513 514 767 768 769; do
  check "x*$n" "$(rep x "$n")"
  check "q-edge-$n" "$(rep x $((n-1)))\"git commit -n"
  check "bsnl-edge-$n" "$(rep x $((n-1)))\\${NL}it commit -n"
  check "bsnl-edge2-$n" "$(rep x $((n-2)))\\${NL}it commit -n"
  check "bsnl-edge3-$n" "$(rep x "$n")\\${NL}it"
done
check "two backslash-newlines" "g\\\\${NL}it"        # backslash, backslash, NL
check "bs-bs-nl-at-edge" "$(rep x 254)\\\\${NL}it"
check "multibyte" "$(rep 'é;' 200)$(rep '日|' 200)"
check "multibyte-edge" "$(rep x 255)é\\${NL}git"
check "400 continuations" "$(rep "a\\${NL}" 400)git"
check "quotes and subshells" "$(rep '"$( x )"' 1200)git"
check "empty" ""
[ "$fail" = 0 ] && echo "differential: all equal"
exit "$fail"
SH
bash "$d/diff.sh" "$d/new.sh"; echo "bash ${BASH_VERSION}: exit=$?"
```
    Expected: `differential: all equal` (fatal diffs compare sliced vs unsliced with the correct pattern). RAN once on macOS bash 3.2.57 while writing this (self-check): `differential: all equal`, 46 `info:` lines (expected there: main's old pattern is the bug), several minutes because the unsliced oracle is quadratic on 3.2; on bash 4/5 it is fast. UNTESTED on bash 4/5. Any `info:` line on bash 4/5 means main's old pattern also failed there: report which cases, it is not a regression. Then also run the real guards (the repo's own tests): `tests/lib/bats-core/bin/bats tests/test_hooks.bats`, and confirm by hand that `g\<NL>it commit -n` is blocked:
```bash
jq -n --arg c $'g\\\nit commit -n -m x' '{tool_name:"Bash",tool_input:{command:$c}}' | bash hooks/scripts/pre-bash-no-bypass.sh; echo "exit=$?"   # expect 2 (blocked)
```
    (Payload shape read from `hooks/scripts/pre-bash-no-bypass.sh`: `.tool_name == "Bash"`, `.tool_input.command`. If the hook needs `GRID_*` env or a git cwd, copy the invocation from `run_hook` in `tests/test_hooks.bats`.)
11. [ ] Shellcheck on the changed files: `shellcheck hooks/lib/common.sh hooks/lib/auto-handoff-worker.sh hooks/scripts/pre-bash-no-bypass.sh hooks/scripts/pre-bash-secret-scan.sh scripts/catalog.sh` (gate covers it; run once by hand to read the findings).

## 5. STEP B: merge decision

```bash
git push origin fix/macos-bats             # only if you added fix commits
gh pr checks 301
gh pr view 301 --json body --jq .body > /tmp/pr301.md   # then append a "Linux results" section
gh pr edit 301 --body-file /tmp/pr301.md
gh pr merge 301 --squash                    # or the repo's usual style; only when checks are green
```

- Put in the PR body: Linux version info (`uname -sr; bash --version | head -1; python3 -V; shellcheck --version | head -2`), gate result, bats `1..N` line, every item from section 4 as RAN/UNTESTED.
- The branch history carries `GRID_SKIP_HOOK=1` commits. The pre-commit hook runs for NEW commits on Linux, where the gate should pass.
- Do not merge on a red or skipped-in-CI check. Do not merge your own work to production without the human.

## 6. STEP C: bring your own in-flight branch up to date

After #301 lands on `main`:

Overlap check first (before #301 lands; after it lands use `git diff --name-only <merge-base>..origin/main`):

```bash
git fetch origin
comm -12 <(git diff --name-only main...<your-branch> | sort) <(gh pr diff 301 --name-only | sort)
```

High-conflict files (touched here, likely touched by you):
- `tests/helpers/setup.bash`
- `tests/test_hooks.bats`
- `hooks/lib/common.sh`
- `scripts/catalog.sh`
- `tests/test_plugins.bats`
- `tests/test_auto_handoff.bats`
- `tests/test_instincts_capture.bats`

Then:
1. `git checkout <your-branch>`, then `git rebase origin/main` (or `git merge origin/main` if the branch is shared). On conflict, keep BOTH intents: your logic plus the portable form from #301. Do not revert a portability change to resolve.
2. `bash scripts/gate.sh`, then the full bats suite in the background as in Step A.
3. Review the NEW code on your branch against `docs/portability.md`: `git diff origin/main...HEAD -- '*.sh' '*.bash' '*.bats' '*.py'` and walk the "Avoid" table (coproc, `grep -P`, `stat -c`, `lines[-1]`, bare `mktemp`, `sed -i` with no suffix, etc.).
4. If a Mac is reachable, run the touched `.bats` files there under `/bin/bash` 3.2 (Step D); otherwise note UNTESTED-on-macOS in your PR.

## 7. STEP D: macOS follow-up (person on the Mac, after both merges)

```bash
cd ~/.the-grid
git checkout main && git pull --ff-only
bash scripts/wire.sh
git checkout SKILLS.md              # wire.sh regenerates it; repos/ecc is uninitialised on this machine, so the diff is machine noise
git status --short                  # expect only untracked local files
# full suite, in the background (10+ minutes)
tests/lib/bats-core/bin/bats tests/ > "$TMPDIR/bats-mac.log" 2>&1; echo "exit=$?" >> "$TMPDIR/bats-mac.log"
```

- Expect near-green: 0 `not ok`, about 33 skips (the NBSP probe skips, the `daily` hostname skip, APFS case skips, etc.).
- Known remaining failures on macOS: none known.
- Any new failure is a regression from the Linux work: fix it with the helpers in `docs/portability.md`.

## 8. OPTIONAL: a macOS CI job (NEEDS THE OPERATOR'S CALL)

Do not add this without the operator deciding. Trade-offs:

- Benefit: catches Mac breakage on every PR instead of after the fact.
- Cost: macOS runner minutes are billed at a multiple of Linux minutes, and the full suite takes 10+ minutes (the Linux job shards it; see `tests/shards.txt`).
- Options:
  1. every PR
  2. only PRs touching `tests/**`, `hooks/**`, `scripts/**` (path filter)
  3. nightly on `main`
  4. non-required / advisory (`continue-on-error: true`)
- Trap: hosted macOS runners put a newer Homebrew bash first on PATH. This PR's bats results were verified under `/bin/bash` 3.2.57, so a CI job must run bats with `/bin/bash`, system python 3.9, and NO GNU `timeout` (do not `brew install coreutils`), or it will not reproduce the failures this PR fixed.

Skeleton only (NOT committed as a workflow):

```yaml
# .github/workflows/macos.yml  -- sketch, needs the operator's go-ahead
on:
  pull_request:
    paths: ['tests/**', 'hooks/**', 'scripts/**']   # option 2; drop for option 1
jobs:
  bats-macos:
    runs-on: macos-15                 # pin an image, as tests.yml does for ubuntu
    continue-on-error: true           # option 4; remove once stable
    timeout-minutes: 45
    steps:
      - uses: actions/checkout@<pin the same sha as tests.yml>
        with: { submodules: recursive, persist-credentials: false }
      - name: Show what we are really testing
        run: /bin/bash --version | head -1; /usr/bin/python3 -V; command -v timeout || echo "no GNU timeout (expected)"
      - name: bats under system bash
        # Invoke bats via /bin/bash explicitly: a Homebrew bash earlier on PATH would hide the bash 3.2 failures.
        run: /bin/bash tests/lib/bats-core/bin/bats tests/
```

## 9. Known open items

- GitHub issue #302: secret scan strict mode misses NBSP-in-value on macOS UTF-8 (the `test_hooks.bats` NBSP expectation is skipped there, not fixed).
- Bare `mktemp` (macOS ignores TMPDIR) remains in: `scripts/sources.sh`, `scripts/runtime-setup.sh`, `scripts/wire.sh`, `scripts/build-personas.sh`, `scripts/reconcile.sh`, `scripts/audit.sh`, `scripts/instantiate.sh`, `scripts/lib/render-schedule.sh`. Scratch files only; suite passes; follow-up (`${TMPDIR:-/tmp}/name.XXXXXX`).
- `tests/test_plugins.bats` hostname check is skipped on a host literally named `daily`.
- `tests/test_hooks.bats` NBSP expectation skipped where libc treats NBSP as `[[:space:]]`.
- `readlink -f` was checked OK on macOS 26 but is not guaranteed on older macOS.
- UNTESTED: Linux (any distro), bash 4/5, shellcheck on the changed files, python 3.10+ for `miniyaml`, the differential in 4.10.

## Linux results (2026-10-30, branch head c3ecdc1)

Linux box: bash 5.2.21, python 3.12.3, GNU userland.

- CI: `checks`, `bats s1` to `s4` and `gate` all green. The only failure before the fix was shellcheck SC2120 on `mktemp_canon` (suppressed in c3ecdc1); shellcheck now passes on every changed shell file.
- 4.10 differential (`_grid_unquote`, `_grid_count_tokens` against the unsliced oracle): all equal. The guard `g\<NL>it commit -n` is blocked (exit 2).
- 4.2, 4.3, 4.5 (bad baseline exits 2) and 4.7 (4299 and 4300 digits parse, 4301 raises) ran and passed. The rest of section 4 was not run by hand; CI's bats shards cover it.
- Security review of the guard-hook changes (read-only, adversarial inputs through the real hooks): no fail-open regression, verdict MERGE.
  - 5505 of 5505 evasive variants blocked at padding offsets 0 to 1100, identical to the old tree.
  - A 2000-string fuzz of the unquote and token-count helpers matched the oracle in C and C.UTF-8 locales.
  - On bash 5.2 the old backslash-newline pattern also worked; the new one is a bash 3.2 fix only.
  - Notes (low): a `TMPDIR` starting with `-` would be read as a `mktemp` option; `catalog.sh --check` exit 0 on a clean tree needs initialised submodules to confirm.
  - Not tested: bash 3.2 timing and slice behaviour (macOS only), `hooks/run.sh` as the launcher, locales other than C and C.UTF-8.

## 10. Cleanup (merge-follow-up)

Keep this file. Only tidy branches and worktrees:

```bash
git worktree list && git worktree prune
git branch --merged origin/main | grep -v '^\*\|main$'   # delete only branches confirmed merged or contained in origin/main
git branch -d fix/macos-bats                   # after the PR shows MERGED
```

Report per repo rule 16: for each branch touched (`fix/macos-bats`, your in-flight branch) state merged or open, the PR number, and what blocks merge. Leave no scratch worktrees under `.claude/worktrees` or `/tmp`.
