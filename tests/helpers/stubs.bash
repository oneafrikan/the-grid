#!/usr/bin/env bash
# tests/helpers/stubs.bash — THE stub helper for every bats test that needs fake
# external commands (G5: extend this file, never fork it).
#
#   load helpers/stubs
#   make_stubs [--claude-in-local-bin]     # in setup(); needs $HOME already pointed at a temp dir
#   clean_stubs                            # in teardown()
#   stub_issue <N> <title> <body> [label...]   # fixture for `gh issue view N`
#
# make_stubs creates a temp stub dir, PREPENDS it to PATH and writes fake
#   gh  claude  loginctl  timeout  systemctl  launchctl  crontab
# Every stub appends one line of its argv to $STUB_LOG (empty args are shown as
# "", newlines as spaces, so one call is one line and `--tools ""` greps
# literally). Nothing here makes a network call or a model call.
# `claude` is also exported as $GRID_CLAUDE (agent-factory/run_evals.py
# convention), so code that honours that variable reaches the stub.
# With --claude-in-local-bin the claude stub lives in $HOME/.local/bin and that
# dir is NOT added to PATH (to test the runner's own PATH handling for a native
# install).
#
# "<N>" below is an issue number: the stubs read STUB_X_<N> first and fall back to
# STUB_X, so one test can give issue 5 a different fate than issue 6.
#
# Variables a test may set (all optional; read at call time by the stubs):
#   STUB_LOG                 where calls are logged (default $STUB_DIR/calls.log)
#
#   claude
#     `claude --help` and `claude auth status` are NOT logged: they are not model calls.
#     STUB_CLAUDE_READ_STDIN=1  `--help` and `auth status` first read stdin to EOF (models a child touching the terminal)
#     STUB_CLAUDE_EXIT[_N]     exit status of a `-p` call (default 0)
#     STUB_CLAUDE_JSON[_N]     stdout of a worker `-p ... --output-format json` call
#                              (default a success result with total_cost_usd 0.01)
#     STUB_REVIEW_JSON, STUB_REVIEW_EXIT   the same for the review call (the one without
#                              $LOOP_OUTCOME_FILE); default result "- [nit] stub review\nVERDICT: approve"
#     STUB_CLAUDE_HELP         text printed for `claude --help` (default: no --max-turns)
#     STUB_CLAUDE_LOGGED_IN    1 (default) or 0: `claude auth status --json` (0 also exits 1, as the real one does)
#     STUB_ENV_LOG             per `-p` call: GH_TOKEN, GITHUB_TOKEN, CLAUDE_CODE_OAUTH_TOKEN
#                              (value or <unset>), stdin byte count, cwd (default $STUB_DIR/env.log)
#     STUB_WORKER_COMMIT[_N]=1 a worker call (LOOP_OUTCOME_FILE set) creates and commits a file in its cwd
#     STUB_OUTCOME[_N]         line written to $LOOP_OUTCOME_FILE (default "done"); STUB_NO_OUTCOME=1 writes none
#     STUB_CLAUDE_SLEEP[_N]    seconds a worker call sleeps first; $STUB_STARTED (a path) is touched when it starts
#     STUB_HANG_AFTER_OUTCOME  seconds a worker call keeps running after writing its outcome, with no result printed
#     STUB_PLANT_PREPUSH       path: the worker plants a pre-push hook that touches it
#     STUB_CLAUDE_ARGV         path: the last `-p` call's argv is written there, NUL separated
#     STUB_STDIN_DUMP          path: the last `-p` call's stdin is copied there
#     STUB_CLAUDE_STDIN        path: every `-p` call's drained stdin is copied there (same as STUB_STDIN_DUMP)
#     STUB_CLAUDE_STDOUT       path: a file whose bytes every `-p` call prints verbatim on stdout (after draining
#                              stdin), then exits STUB_CLAUDE_EXIT (default 0); used by the README translator tests
#     Every call also records, in $STUB_DIR: claude.cwd, claude.child-env (GRID_AUTOHANDOFF_CHILD),
#     claude.pgid, claude.pid, claude.umask, claude.env (the full environment it received)
#     (auto-handoff tests). WP-016 modes: handoff-outside ($STUB_OUTSIDE_FILE), handoff-home-dotfile
#     ($HOME/.bashrc), handoff-symlink, handoff-githook-other (git internals of $STUB_HANDOFF_DIR's repo).
#     WP-017/018 knobs for handoff-* modes: STUB_HANDOFF_PREFIX (distinct pair names), STUB_CLAUDE_GRANDCHILD=1
#     (a lingering grandchild, pid in grandchild.pid), STUB_CLAUDE_SLEEP_AFTER (linger after writing),
#     STUB_CLAUDE_PRINT (text printed on stdout); modes handoff-modify (edits base.txt), handoff-secret-third.
#     STUB_DELETE_FILE (path the handoff-* child removes while it runs).
#     STUB_CLAUDE_MODE         unset = the behaviour above. handoff-logs | handoff-fallback | handoff-target |
#                              handoff-extra | handoff-stray act like the auto-handoff child: write
#                              2026-01-01-testhost-stub-{handoff,context}.md (body ${STUB_HANDOFF_BODY:-stub}) into
#                              $PWD/LOGS, $GRID_HANDOFF_FALLBACK_DIR/<basename PWD>, $STUB_HANDOFF_DIR, $PWD/LOGS
#                              (+ .git/hooks/x and a line in .git/config), $PWD/LOGS (+ a/b/c/d/e/stray.md), then
#                              exit $STUB_CLAUDE_EXIT (default 0). They first sleep STUB_CLAUDE_SLEEP seconds and
#                              copy the digest named in the prompt to $STUB_DIR/claude.digest.
#     An "analyser" call (argv has --system-prompt: scripts/instincts/analyse.py) is neither worker nor
#     review: it sleeps STUB_CLAUDE_SLEEP seconds first, then prints STUB_CLAUDE_JSON verbatim (default
#     the success envelope) and exits STUB_CLAUDE_EXIT (default 0).
#
#   gh   (each call logs `gh <args> ::GH_TOKEN=<value|<unset>>`)
#     STUB_PR_NUMBER           number printed by `gh pr view --json number -q .number`
#                              (default empty: exit 1 "no pull requests found")
#     STUB_LABELS              JSON printed by `gh label list ... --json name` (default [])
#     STUB_GH_STORED_LOGIN     1 makes `gh auth status` succeed (default: it fails)
#     STUB_ISSUES              issue numbers printed by `gh issue list` (space or newline separated)
#     stub_issue N ...         fixture file $STUB_DIR/issue-N.json for `gh issue view N` (default:
#                              title "Issue N", body "Do N", label ready-for-agent)
#     STUB_PR_EXISTS_FOR       issue numbers that already have an open PR (`gh pr list --head issue-N`)
#     STUB_NEW_PR              number in the URL `gh pr create` prints (default 101); STUB_PR_CREATE_FAIL=1 fails it;
#                              its --body-file is kept as $STUB_DIR/pr-create.body
#     STUB_NEW_ISSUE           number in the URL `gh issue create` prints (default 201); STUB_REPO sets the owner/name
#     STUB_DIFF_LINES          lines `gh pr diff` prints (default 5)
#     STUB_COMMENTS            file collecting "<cmd> <number>: <body-file text>" for issue/pr comments
#                              (default $STUB_DIR/comments.log)
#     STUB_REPO                owner/name in the URL `gh pr create` prints (default owner/name)
#     STUB_AUTHOR_ASSOC[_N]    `author_association` of issue N (default OWNER); `gh api repos/R/issues/N`
#                              answers the stub_issue fixture (title, body, labels) plus that field;
#                              STUB_ISSUE_API_FAIL=1 makes it fail
#     STUB_COMMENTS_JSON[_N]   answer of `gh api repos/R/issues/N/comments` (default []); STUB_COMMENTS_FAIL=1 fails it
#     STUB_REPO_VIEW_JSON      answer of `gh repo view` (default: empty description/homepage, repositoryTopics null);
#                              `gh repo edit` just logs its argv and exits 0
#
#   loginctl
#     STUB_LINGER              value printed for `show-user ... --value` (default yes)
#     STUB_LOGINCTL_FAIL       1 makes every loginctl call exit 1
#
#   timeout
#     Drops `-k N` / `--kill-after N|=N`, `-s SIG` / `--signal SIG|=SIG`, `--foreground`,
#     `--preserve-status` and the SECS argument, then execs the rest (tests/test_stubs.bats).
#
#   systemctl, launchctl, crontab
#     Log their argv and do nothing: a test asserts they were never called.
#

make_stubs() {
  local claude_in_local_bin=0
  [ "${1:-}" = "--claude-in-local-bin" ] && claude_in_local_bin=1

  STUB_DIR="$(mktemp -d)"
  export STUB_DIR
  : "${STUB_LOG:=$STUB_DIR/calls.log}"
  export STUB_LOG
  : > "$STUB_LOG"
  export STUB_ENV_LOG="$STUB_DIR/env.log"
  export STUB_COMMENTS="$STUB_DIR/comments.log"
  : > "$STUB_ENV_LOG"; : > "$STUB_COMMENTS"

  local claude_dir="$STUB_DIR"
  if [ "$claude_in_local_bin" = 1 ]; then
    claude_dir="$HOME/.local/bin"
    mkdir -p "$claude_dir"
  fi

  # ---- shared library, sourced by every stub (absolute path) ----
  # stub_log <name> <args...>: one line per call, empty args as "", newlines as spaces,
  # plus $STUB_LOG_SUFFIX. pick <NAME> <N>: value of STUB_<NAME>_<N>, else STUB_<NAME>, else "".
  local lib="$STUB_DIR/.stub-lib.sh"
  cat > "$lib" <<'EOF'
stub_log() {
  local line="$1"; shift
  local a
  for a in "$@"; do
    if [ -z "$a" ]; then line="$line \"\""; else line="$line ${a//$'\n'/ }"; fi
  done
  printf '%s\n' "$line${STUB_LOG_SUFFIX:-}" >> "${STUB_LOG:-/dev/null}"
}
pick() {
  local val=""
  if [ -n "${2:-}" ]; then eval "val=\"\${STUB_$1_$2:-}\""; fi
  if [ -z "$val" ]; then eval "val=\"\${STUB_$1:-}\""; fi
  printf '%s' "$val"
}
EOF

  # ---- claude ----
  {
    printf '%s\n' '#!/bin/bash'
    printf '. %s\n' "$lib"
    cat <<'EOF'
if [ "${STUB_CLAUDE_READ_STDIN:-0}" = 1 ] && { [ "${1:-}" = "--help" ] || [ "${1:-}" = "auth" ]; }; then cat > /dev/null; fi
case "${1:-}" in
  --help|-h)
    if [ -n "${STUB_CLAUDE_HELP:-}" ]; then printf '%s\n' "$STUB_CLAUDE_HELP"
    else printf 'Usage: claude [options]\n  --model <m>\n  --max-budget-usd <n>\n  --output-format <f>\n'; fi
    exit 0 ;;
  auth)
    # The real `claude auth status` exits 1 when logged out (R16.qa.F10), so a caller that
    # forgets to handle that status is caught here, not only on a real logged-out machine.
    if [ "${STUB_CLAUDE_LOGGED_IN:-1}" = 1 ]; then echo '{"loggedIn": true, "authMethod": "stub"}'; exit 0
    else echo '{"loggedIn": false}'; exit 1; fi ;;
esac
stub_log claude "$@"
# STUB_CLAUDE_ARGV (a path): the last `-p` call's argv, NUL separated, so a test can read the prompt
# and each flag value exactly (the one-line log above joins words and flattens newlines).
if [ -n "${STUB_CLAUDE_ARGV:-}" ]; then printf '%s\0' "$@" > "$STUB_CLAUDE_ARGV"; fi
# ---- auto-handoff worker call (hook-profiles group 3) ----
# Facts about this process, recorded on every run for the worker tests: cwd, the
# recursion-guard env value, the process group (compared with the test's own), the pid
# (killed or checked by the timeout test) and the umask. Nothing else reads them.
if [ -n "${STUB_DIR:-}" ]; then
  pwd > "$STUB_DIR/claude.cwd"
  printf '%s' "${GRID_AUTOHANDOFF_CHILD:-}" > "$STUB_DIR/claude.child-env"
  ps -o pgid= -p $$ | tr -d ' ' > "$STUB_DIR/claude.pgid"
  echo $$ > "$STUB_DIR/claude.pid"
  umask > "$STUB_DIR/claude.umask"
  env > "$STUB_DIR/claude.env"   # the environment the worker handed the child (WP-016)
fi
# STUB_CLAUDE_MODE=handoff-* acts like the real child of hooks/lib/auto-handoff-worker.sh:
# it writes the two handoff files and leaves. Unset (the default) = the old behaviour below.
case "${STUB_CLAUDE_MODE:-}" in
  handoff-*)
    # Keep a copy of the digest the prompt names, so a test can read what the child saw.
    digest="$(printf '%s' "$*" | sed -n 's/.*digest file \([^ ]*\), not this session.*/\1/p')"
    if [ -n "$digest" ] && [ -f "$digest" ] && [ -n "${STUB_DIR:-}" ]; then cp "$digest" "$STUB_DIR/claude.digest"; fi
    # STUB_CLAUDE_GRANDCHILD=1: leave a long-lived grandchild behind (its pid in grandchild.pid), as a
    # real child's tool process would; the worker's timeout must kill it too (WP-017).
    if [ "${STUB_CLAUDE_GRANDCHILD:-0}" = 1 ]; then sleep 300 > /dev/null 2>&1 3>&- & echo $! > "$STUB_DIR/grandchild.pid"; fi
    # STUB_CLAUDE_IGNORE_TERM=1: ignore TERM and never exit on its own (only KILL ends it): pins the
    # worker's TERM-then-KILL of the child's process group.
    if [ "${STUB_CLAUDE_IGNORE_TERM:-0}" = 1 ]; then trap '' TERM; while :; do sleep 1; done; fi
    # STUB_SIDE_FILE: another process writes this file while the child runs (simulates a sibling session).
    if [ -n "${STUB_SIDE_FILE:-}" ]; then mkdir -p "$(dirname "$STUB_SIDE_FILE")"; echo "from another agent" > "$STUB_SIDE_FILE"; fi
    # STUB_DELETE_FILE: the child removes this file (hardening H-02: a deletion must be reported).
    if [ -n "${STUB_DELETE_FILE:-}" ]; then rm -f "$STUB_DELETE_FILE"; fi
    if [ -n "${STUB_CLAUDE_SLEEP:-}" ]; then sleep "$STUB_CLAUDE_SLEEP"; fi
    # STUB_HANDOFF_PREFIX makes the pair's names distinct, so two sessions in one cwd (WP-017) can be told apart.
    hf="${STUB_HANDOFF_PREFIX:-}2026-01-01-testhost-stub-handoff.md"
    cf="${STUB_HANDOFF_PREFIX:-}2026-01-01-testhost-stub-context.md"
    body="${STUB_HANDOFF_BODY:-stub}"
    # write_pair <dir>: both handoff files into <dir>
    write_pair() { mkdir -p "$1"; printf '%s\n' "$body" > "$1/$hf"; printf '%s\n' "$body" > "$1/$cf"; }
    case "$STUB_CLAUDE_MODE" in
      handoff-logs)     write_pair "$PWD/LOGS" ;;
      handoff-fallback) write_pair "$GRID_HANDOFF_FALLBACK_DIR/$(basename "$PWD")" ;;
      handoff-target)   write_pair "$STUB_HANDOFF_DIR" ;;
      handoff-extra)    # a planted git hook and a changed git config (the write-only boundary failing)
        write_pair "$PWD/LOGS"
        mkdir -p "$PWD/.git/hooks"
        printf '#!/bin/sh\n' > "$PWD/.git/hooks/x"
        echo '[stub] changed = 1' >> "$PWD/.git/config" ;;
      handoff-stray)    # a deep stray file (deeper than the old depth-4 scan)
        write_pair "$PWD/LOGS"
        mkdir -p "$PWD/a/b/c/d/e"
        echo stray > "$PWD/a/b/c/d/e/stray.md" ;;
      # WP-016: the write-only boundary failing in ways the original scan could not see.
      handoff-outside)  # the pair, plus a file at $STUB_OUTSIDE_FILE (outside the target dir)
        write_pair "$PWD/LOGS"
        printf '%s\n' "${STUB_OUTSIDE_BODY:-x}" > "$STUB_OUTSIDE_FILE" ;;
      handoff-home-dotfile)  # the pair, plus a line appended to the shell rc file
        write_pair "$PWD/LOGS"
        echo 'echo planted' >> "$HOME/.bashrc" ;;
      handoff-modify)  # the pair, plus an edit to a tracked file
        write_pair "$PWD/LOGS"
        echo more >> "$PWD/base.txt" ;;
      handoff-symlink)  # the pair, plus a new symlink beside it
        write_pair "$PWD/LOGS"
        ln -s /etc/hostname "$PWD/LOGS/evil-link" ;;
      handoff-githook-other)  # the pair into $STUB_HANDOFF_DIR (a repo), plus git internals of THAT repo
        write_pair "$STUB_HANDOFF_DIR"
        g="$(git -C "$STUB_HANDOFF_DIR" rev-parse --absolute-git-dir)"
        mkdir -p "$g/hooks" "$g/info"
        printf '#!/bin/sh\n' > "$g/hooks/post-commit"
        echo '# planted' >> "$g/info/exclude"
        : > "$g/HEAD.evil" ;;
      # WP-016/018 review follow-ups
      handoff-nested-git)  # the pair into $STUB_HANDOFF_DIR plus a NEW .git there whose config would run $STUB_CANARY_CMD
        write_pair "$STUB_HANDOFF_DIR"
        mkdir -p "$STUB_HANDOFF_DIR/.git/objects" "$STUB_HANDOFF_DIR/.git/refs"
        printf 'ref: refs/heads/main\n' > "$STUB_HANDOFF_DIR/.git/HEAD"
        printf '[core]\n\trepositoryformatversion = 0\n\tfsmonitor = %s\n' "$STUB_CANARY_CMD" > "$STUB_HANDOFF_DIR/.git/config" ;;
      handoff-leak)  # NO pair; a secret-bearing stray file instead
        mkdir -p "$PWD/LOGS"; printf '%s\n' "$body" > "$PWD/leak.txt" ;;
      handoff-symlink-dir)  # the pair, plus a new symlink to a DIRECTORY
        write_pair "$PWD/LOGS"
        ln -s /etc "$PWD/LOGS/etc-link" ;;
      handoff-secret-third)  # the pair (give it a secret body), plus an innocent third file (WP-018)
        write_pair "$PWD/LOGS"
        echo plain > "$PWD/LOGS/third.md" ;;
    esac
    # STUB_CLAUDE_PRINT: text the child prints on stdout (the worker logs it, masked).
    # STUB_CLAUDE_SLEEP_AFTER: seconds to linger AFTER writing (a timeout with files on disk).
    if [ -n "${STUB_CLAUDE_PRINT:-}" ]; then printf '%s\n' "$STUB_CLAUDE_PRINT"; fi
    if [ -n "${STUB_CLAUDE_SLEEP_AFTER:-}" ]; then sleep "$STUB_CLAUDE_SLEEP_AFTER"; fi
    exit "${STUB_CLAUDE_EXIT:-0}" ;;
esac
# issue number from the worktree name (issue-N), if any
n=""
case "$(basename "$(pwd)")" in issue-[0-9]*) n="${PWD##*issue-}" ;; esac
# A real `claude -p` waits for EOF on stdin; the stub drains it the same way and logs the size.
cat > "${TMPDIR:-/tmp}/stub-stdin.$$"
bytes="$(wc -c < "${TMPDIR:-/tmp}/stub-stdin.$$" | tr -d ' ')"
if [ -n "${STUB_STDIN_DUMP:-}" ]; then cp "${TMPDIR:-/tmp}/stub-stdin.$$" "$STUB_STDIN_DUMP"; fi
if [ -n "${STUB_CLAUDE_STDIN:-}" ]; then cp "${TMPDIR:-/tmp}/stub-stdin.$$" "$STUB_CLAUDE_STDIN"; fi
rm -f "${TMPDIR:-/tmp}/stub-stdin.$$"
printf 'GH_TOKEN=%s GITHUB_TOKEN=%s CLAUDE_CODE_OAUTH_TOKEN=%s stdin_bytes=%s cwd=%s\n' \
  "${GH_TOKEN-<unset>}" "${GITHUB_TOKEN-<unset>}" "${CLAUDE_CODE_OAUTH_TOKEN-<unset>}" "$bytes" "$(pwd)" >> "${STUB_ENV_LOG:-/dev/null}"

# STUB_CLAUDE_STDOUT (a path): print that file as the reply and stop, whatever kind of call this is.
if [ -n "${STUB_CLAUDE_STDOUT:-}" ]; then
  cat "$STUB_CLAUDE_STDOUT"
  exit "${STUB_CLAUDE_EXIT:-0}"
fi

if [ -n "${LOOP_OUTCOME_FILE:-}" ]; then
  # ---- worker call ----
  if [ -n "${STUB_STARTED:-}" ]; then : > "$STUB_STARTED"; fi
  sl="$(pick CLAUDE_SLEEP "$n")"
  if [ -n "$sl" ]; then sleep "$sl"; fi
  if [ -n "${STUB_PLANT_PREPUSH:-}" ]; then
    hooks="$(git rev-parse --git-common-dir)/hooks"
    mkdir -p "$hooks"
    printf '#!/bin/sh\ntouch "%s"\n' "$STUB_PLANT_PREPUSH" > "$hooks/pre-push"
    chmod +x "$hooks/pre-push"
  fi
  if [ "$(pick WORKER_COMMIT "$n")" = 1 ]; then
    echo "work for issue ${n:-x}" > "stub-work-${n:-x}.txt"
    git add "stub-work-${n:-x}.txt"
    git commit -q -m "stub work #${n:-x}"
  fi
  if [ "${STUB_NO_OUTCOME:-0}" != 1 ]; then
    oc="$(pick OUTCOME "$n")"
    printf '%s\n' "${oc:-done}" > "$LOOP_OUTCOME_FILE"
  fi
  # STUB_HANG_AFTER_OUTCOME=<seconds>: keep running after the outcome is written, printing no result
  # (a worker whose background watcher keeps the session alive).
  if [ -n "${STUB_HANG_AFTER_OUTCOME:-}" ]; then sleep "$STUB_HANG_AFTER_OUTCOME"; fi
  rc="$(pick CLAUDE_EXIT "$n")"
  js="$(pick CLAUDE_JSON "$n")"
  default_json='{"type":"result","subtype":"success","is_error":false,"result":"stub result","total_cost_usd":0.01}'
  printf '%s\n' "${js:-$default_json}"
  exit "${rc:-0}"
fi
# ---- review (or hook) call ----
want_json=0
analyser=0
prev=""
for a in "$@"; do
  if [ "$prev" = "--output-format" ] && [ "$a" = "json" ]; then want_json=1; fi
  if [ "$a" = "--system-prompt" ]; then analyser=1; fi
  prev="$a"
done
if [ "$analyser" = 1 ]; then
  # ---- analyser call (instincts): its own reply and sleep knobs, so review tests are unaffected ----
  if [ -n "${STUB_CLAUDE_SLEEP:-}" ]; then sleep "$STUB_CLAUDE_SLEEP"; fi
  default_analyse='{"type":"result","subtype":"success","is_error":false,"result":"[]","total_cost_usd":0.01}'
  printf '%s\n' "${STUB_CLAUDE_JSON:-$default_analyse}"
  exit "${STUB_CLAUDE_EXIT:-0}"
fi
if [ "$want_json" = 1 ]; then
  default_review='{"type":"result","subtype":"success","is_error":false,"result":"- [nit] stub review\nVERDICT: approve","total_cost_usd":0.02}'
  printf '%s\n' "${STUB_REVIEW_JSON:-$default_review}"
else
  echo "- [nit] stub review"
  echo "VERDICT: approve"
fi
exit "${STUB_REVIEW_EXIT:-${STUB_CLAUDE_EXIT:-0}}"
EOF
  } > "$claude_dir/claude"
  chmod +x "$claude_dir/claude"
  GRID_CLAUDE="$claude_dir/claude"
  export GRID_CLAUDE

  # ---- gh ----
  {
    printf '%s\n' '#!/bin/bash'
    printf '. %s\n' "$lib"
    cat <<'EOF'
STUB_LOG_SUFFIX=" ::GH_TOKEN=${GH_TOKEN-<unset>}" stub_log gh "$@"
repo="${STUB_REPO:-owner/name}"
# value of --body-file, if any, copied into the comments log
bodyfile=""; prev=""
for a in "$@"; do
  if [ "$prev" = "--body-file" ]; then bodyfile="$a"; fi
  prev="$a"
done
case "${1:-} ${2:-}" in
  "pr view")
    if [ -n "${STUB_PR_NUMBER:-}" ]; then echo "$STUB_PR_NUMBER"; exit 0; fi
    echo "no pull requests found" >&2; exit 1 ;;
  "label list") printf '%s\n' "${STUB_LABELS:-[]}"; exit 0 ;;
  "auth status")
    if [ "${STUB_GH_STORED_LOGIN:-0}" = 1 ]; then exit 0; fi
    echo "You are not logged into any GitHub hosts." >&2; exit 1 ;;
  "issue list")
    for n in ${STUB_ISSUES:-}; do echo "$n"; done
    exit 0 ;;
  "issue view")
    n="$3"
    if [ -f "$STUB_DIR/issue-$n.json" ]; then cat "$STUB_DIR/issue-$n.json"
    else printf '{"title":"Issue %s","body":"Do %s","labels":[{"name":"ready-for-agent"}]}\n' "$n" "$n"; fi
    exit 0 ;;
  "pr list")
    head=""; prev=""
    for a in "$@"; do if [ "$prev" = "--head" ]; then head="$a"; fi; prev="$a"; done
    for n in ${STUB_PR_EXISTS_FOR:-}; do
      if [ "$head" = "issue-$n" ]; then echo 99; fi
    done
    exit 0 ;;
  "pr create")
    if [ "${STUB_PR_CREATE_FAIL:-0}" = 1 ]; then echo "pull request create failed" >&2; exit 1; fi
    # keep the PR body ($STUB_DIR/pr-create.body) so a test can read what the PR text carries
    if [ -n "$bodyfile" ] && [ -f "$bodyfile" ]; then cp "$bodyfile" "$STUB_DIR/pr-create.body"; fi
    echo "https://github.com/$repo/pull/${STUB_NEW_PR:-101}"
    exit 0 ;;
  "pr diff")
    i=1
    while [ "$i" -le "${STUB_DIFF_LINES:-5}" ]; do echo "+diff line $i"; i=$((i + 1)); done
    exit 0 ;;
  "pr comment"|"issue comment")
    if [ -n "$bodyfile" ] && [ -f "$bodyfile" ]; then
      printf '%s %s: %s\n' "$1 $2" "$3" "$(tr '\n' ' ' < "$bodyfile")" >> "${STUB_COMMENTS:-/dev/null}"
    fi
    exit 0 ;;
  "issue create")
    # like the real one: print the new issue's URL (the knowledge sweep reads the number from it)
    echo "https://github.com/$repo/issues/${STUB_NEW_ISSUE:-201}"
    exit 0 ;;
  "issue edit") exit 0 ;;
  "repo view")
    # scripts/repo-metadata.sh; default is a repo with no metadata (gh prints null for no topics)
    empty_repo='{"description":"","homepageUrl":"","repositoryTopics":null}'
    printf '%s\n' "${STUB_REPO_VIEW_JSON:-$empty_repo}"
    exit 0 ;;
esac
if [ "${1:-}" = api ]; then
  case "$*" in
    */issues/*/comments*)
      # comments of issue N: STUB_COMMENTS_JSON[_N] (default no comments); STUB_COMMENTS_FAIL=1 fails the call
      allargs="$*"; n="${allargs%/comments*}"; n="${n##*/}"
      if [ "${STUB_COMMENTS_FAIL:-0}" = 1 ]; then echo "gh: HTTP 500" >&2; exit 1; fi
      cj="$(pick COMMENTS_JSON "$n")"
      printf '%s\n' "${cj:-[]}"; exit 0 ;;
    */issues/*)
      # the issue itself: the stub_issue fixture (title, body, labels) plus author_association
      # (STUB_AUTHOR_ASSOC[_N], default OWNER); STUB_ISSUE_API_FAIL=1 fails the call
      allargs="$*"; n="${allargs##*/}"
      if [ "${STUB_ISSUE_API_FAIL:-0}" = 1 ]; then echo "gh: HTTP 500" >&2; exit 1; fi
      aa="$(pick AUTHOR_ASSOC "$n")"
      if [ -f "$STUB_DIR/issue-$n.json" ]; then base="$(cat "$STUB_DIR/issue-$n.json")"
      else base="{\"title\":\"Issue $n\",\"body\":\"Do $n\",\"labels\":[{\"name\":\"ready-for-agent\"}]}"; fi
      printf '%s' "$base" | jq -c --arg a "${aa:-OWNER}" '. + {state: "open", number: 0, author_association: $a}'
      exit 0 ;;
  esac
fi
exit 0
EOF
  } > "$STUB_DIR/gh"
  chmod +x "$STUB_DIR/gh"

  # ---- loginctl ----
  {
    printf '%s\n' '#!/bin/bash'
    printf '. %s\n' "$lib"
    cat <<'EOF'
stub_log loginctl "$@"
if [ "${STUB_LOGINCTL_FAIL:-0}" = 1 ]; then exit 1; fi
case "${1:-}" in
  show-user) echo "${STUB_LINGER:-yes}" ;;
esac
exit 0
EOF
  } > "$STUB_DIR/loginctl"
  chmod +x "$STUB_DIR/loginctl"

  # ---- timeout (GNU semantics we rely on: [-k N] SECS cmd...) ----
  {
    printf '%s\n' '#!/bin/bash'
    printf '. %s\n' "$lib"
    cat <<'EOF'
stub_log timeout "$@"
# GNU timeout options we drop (R16.qa.F10): the ones that take a value as a separate word,
# the attached forms (--kill-after=N, -k5, -sKILL), and the flags that take none.
while :; do
  case "${1:-}" in
    -k|--kill-after|-s|--signal) shift 2 ;;
    --kill-after=*|--signal=*|-k?*|-s?*|--foreground|--preserve-status) shift ;;
    *) break ;;
  esac
done
shift   # SECS
exec "$@"
EOF
  } > "$STUB_DIR/timeout"
  chmod +x "$STUB_DIR/timeout"

  # ---- scheduler commands: log-only, so a test can prove nothing activates a scheduler ----
  local sched
  for sched in systemctl launchctl crontab; do
    {
      printf '%s\n' '#!/bin/bash'
      printf '. %s\n' "$lib"
      printf 'stub_log %s "$@"\n' "$sched"
      printf 'exit 0\n'
    } > "$STUB_DIR/$sched"
    chmod +x "$STUB_DIR/$sched"
  done

  PATH="$STUB_DIR:$PATH"
  export PATH
}

# refute <cmd...> — fail when the command SUCCEEDS. (bats runs tests under `set -e`, which
# ignores a failing `! cmd`, so a plain `! grep ...` asserts nothing unless it is the last line.)
refute() {
  if "$@"; then echo "refute: command succeeded: $*" >&2; return 1; fi
  return 0
}

# contains <haystack> <needle> / lacks <haystack> <needle> — substring assertions. (On bash 3.2,
# the macOS default, bats does not catch a failing `[[ ... ]]` that is not the last line.)
contains() {
  case "$1" in *"$2"*) return 0 ;; esac
  echo "expected to contain: $2" >&2
  echo "in: $1" >&2
  return 1
}
lacks() {
  case "$1" in *"$2"*) echo "expected NOT to contain: $2" >&2; echo "in: $1" >&2; return 1 ;; esac
  return 0
}

# stub_issue <N> <title> <body> [label...] — fixture for `gh issue view N --json title,body,labels`.
stub_issue() {
  local n="$1" title="$2" body="$3" labels="" l
  shift 3
  for l in "$@"; do labels="$labels,{\"name\":\"$l\"}"; done
  labels="${labels#,}"
  # body via a file: a single --arg over 128 KiB hits the Linux per-argument limit (E2BIG)
  printf '%s' "$body" > "$STUB_DIR/issue-$n.body"
  jq -n --arg t "$title" --rawfile b "$STUB_DIR/issue-$n.body" --argjson l "[${labels}]" '{title:$t,body:$b,labels:$l}' > "$STUB_DIR/issue-$n.json"
}

# After this PATH still lists the removed stub dir, so a command a test left running in the
# background (a detached hook) resolves the REAL gh/claude from then on. The "no network,
# no model call" promise in the header holds only while the stub dir exists: wait for
# background work to finish before calling this (see tests/test_issue_loop_hooks.bats).
clean_stubs() {
  if [ -n "${STUB_DIR:-}" ]; then rm -rf "$STUB_DIR"; fi
  unset STUB_DIR STUB_LOG STUB_ENV_LOG STUB_COMMENTS GRID_CLAUDE
}
