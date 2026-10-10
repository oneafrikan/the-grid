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
#   gh  claude  curl  loginctl  timeout  systemctl  launchctl  crontab
# plus a GitHub-App token minter exported as $GRID_APP_TOKEN_BIN.
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
#     STUB_CLAUDE_EXIT[_N]     exit status of a `-p` call (default 0)
#     STUB_CLAUDE_JSON[_N]     stdout of a worker `-p ... --output-format json` call
#                              (default a success result with total_cost_usd 0.01)
#     STUB_REVIEW_JSON, STUB_REVIEW_EXIT   the same for the review call (the one without
#                              $LOOP_OUTCOME_FILE); default result "- [nit] stub review\nVERDICT: approve"
#     STUB_CLAUDE_HELP         text printed for `claude --help` (default: no --max-turns)
#     STUB_CLAUDE_LOGGED_IN    1 (default) or 0: `claude auth status --json`
#     STUB_ENV_LOG             per `-p` call: GH_TOKEN, GITHUB_TOKEN, CLAUDE_CODE_OAUTH_TOKEN
#                              (value or <unset>), stdin byte count, cwd (default $STUB_DIR/env.log)
#     STUB_WORKER_COMMIT[_N]=1 a worker call (LOOP_OUTCOME_FILE set) creates and commits a file in its cwd
#     STUB_OUTCOME[_N]         line written to $LOOP_OUTCOME_FILE (default "done"); STUB_NO_OUTCOME=1 writes none
#     STUB_CLAUDE_SLEEP[_N]    seconds a worker call sleeps first; $STUB_STARTED (a path) is touched when it starts
#     STUB_PLANT_PREPUSH       path: the worker plants a pre-push hook that touches it
#     STUB_STDIN_DUMP          path: the last `-p` call's stdin is copied there
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
#     STUB_NEW_PR              number in the URL `gh pr create` prints (default 101); STUB_PR_CREATE_FAIL=1 fails it
#     STUB_DIFF_LINES          lines `gh pr diff` prints (default 5)
#     STUB_COMMENTS            file collecting "<cmd> <number>: <body-file text>" for issue/pr comments
#                              (default $STUB_DIR/comments.log)
#     STUB_REPO                owner/name in the installation-repositories answer (default owner/name)
#     STUB_AUTHOR_ASSOC[_N]    `author_association` of issue N (default OWNER)
#     STUB_ISSUE_LABEL         the opt-in label in the default `labeled` event (default ready-for-agent)
#     STUB_EVENTS_JSON[_N]     answer of `gh api --paginate repos/*/issues/N/events`
#                              (default one `labeled` event by `trusted`)
#     STUB_EDITORS_JSON[_N]    answer of `gh api graphql` (default: no body edits)
#     STUB_RULES_JSON          answer of `gh api repos/*/rules/branches/*` (default one pull_request rule)
#     STUB_INSTALL_REPOS_JSON  answer of `gh api /installation/repositories` (default lists $STUB_REPO)
#     STUB_API_USER_OK         1 makes `gh api user` succeed (models a PAT); default it fails with HTTP 403
#
#   mint stub ($GRID_APP_TOKEN_BIN; prints {"token":...,"permissions":...})
#     STUB_APP_TOKEN           token (default abc);  STUB_APP_TOKEN_SEQ=1 makes it tok1, tok2, ... per call
#     STUB_APP_PERMS           permissions object JSON (default contents/pull_requests/issues write, metadata read)
#     STUB_APP_MINT_FAIL=1     fail with a stderr line;  STUB_APP_MINT_FAIL_AFTER=N fails every call after the Nth
#     STUB_MINT_LOG            one line per call (default $STUB_DIR/mint.log)
#
#   loginctl
#     STUB_LINGER              value printed for `show-user ... --value` (default yes)
#     STUB_LOGINCTL_FAIL       1 makes every loginctl call exit 1
#
#   timeout
#     Drops `-k N` / `--kill-after N` and the SECS argument, then execs the rest.
#
#   systemctl, launchctl, crontab
#     Log their argv and do nothing: a test asserts they were never called.
#
#   curl  (answers the GitHub App token endpoints; honours -o FILE and -w '%{http_code}')
#     STUB_INSTALLATIONS_JSON   body of GET  */app/installations   (default one element, id 4242)
#     STUB_INSTALLATIONS_CODE   its HTTP status                      (default 200)
#     STUB_TOKEN_JSON           body of POST */access_tokens        (default token + expires_at + permissions)
#     STUB_TOKEN_CODE           its HTTP status                      (default 201)
#     any other URL answers 404 {}. The whole argv is logged on one line.

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
  export STUB_MINT_LOG="$STUB_DIR/mint.log"
  : > "$STUB_ENV_LOG"; : > "$STUB_COMMENTS"; : > "$STUB_MINT_LOG"

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
case "${1:-}" in
  --help|-h)
    if [ -n "${STUB_CLAUDE_HELP:-}" ]; then printf '%s\n' "$STUB_CLAUDE_HELP"
    else printf 'Usage: claude [options]\n  --model <m>\n  --max-budget-usd <n>\n  --output-format <f>\n'; fi
    exit 0 ;;
  auth)
    if [ "${STUB_CLAUDE_LOGGED_IN:-1}" = 1 ]; then echo '{"loggedIn": true, "authMethod": "stub"}'
    else echo '{"loggedIn": false}'; fi
    exit 0 ;;
esac
stub_log claude "$@"
# issue number from the worktree name (issue-N), if any
n=""
case "$(basename "$(pwd)")" in issue-[0-9]*) n="${PWD##*issue-}" ;; esac
# A real `claude -p` waits for EOF on stdin; the stub drains it the same way and logs the size.
cat > "${TMPDIR:-/tmp}/stub-stdin.$$"
bytes="$(wc -c < "${TMPDIR:-/tmp}/stub-stdin.$$" | tr -d ' ')"
if [ -n "${STUB_STDIN_DUMP:-}" ]; then cp "${TMPDIR:-/tmp}/stub-stdin.$$" "$STUB_STDIN_DUMP"; fi
rm -f "${TMPDIR:-/tmp}/stub-stdin.$$"
printf 'GH_TOKEN=%s GITHUB_TOKEN=%s CLAUDE_CODE_OAUTH_TOKEN=%s stdin_bytes=%s cwd=%s\n' \
  "${GH_TOKEN-<unset>}" "${GITHUB_TOKEN-<unset>}" "${CLAUDE_CODE_OAUTH_TOKEN-<unset>}" "$bytes" "$(pwd)" >> "${STUB_ENV_LOG:-/dev/null}"

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
  rc="$(pick CLAUDE_EXIT "$n")"
  js="$(pick CLAUDE_JSON "$n")"
  default_json='{"type":"result","subtype":"success","is_error":false,"result":"stub result","total_cost_usd":0.01}'
  printf '%s\n' "${js:-$default_json}"
  exit "${rc:-0}"
fi
# ---- review (or hook) call ----
want_json=0
prev=""
for a in "$@"; do
  if [ "$prev" = "--output-format" ] && [ "$a" = "json" ]; then want_json=1; fi
  prev="$a"
done
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
  "issue edit") exit 0 ;;
esac
repos_default="{\"repositories\":[{\"full_name\":\"$repo\"}]}"
rules_default='[{"type":"pull_request"}]'
if [ "${1:-}" = api ]; then
  case "$*" in
    *graphql*)
      n=""; prev=""
      for a in "$@"; do
        if [ "$prev" = "-F" ]; then case "$a" in n=*) n="${a#n=}" ;; esac; fi
        prev="$a"
      done
      default_ed='{"data":{"repository":{"issue":{"userContentEdits":{"nodes":[]}}}}}'
      ed="$(pick EDITORS_JSON "$n")"
      printf '%s\n' "${ed:-$default_ed}"; exit 0 ;;
    *user)
      if [ "${STUB_API_USER_OK:-0}" = 1 ]; then echo '{"login":"a-pat-user"}'; exit 0; fi
      echo "gh: Resource not accessible by integration (HTTP 403)" >&2; exit 1 ;;
    */installation/repositories*|*" installation/repositories"*)
      printf '%s\n' "${STUB_INSTALL_REPOS_JSON:-$repos_default}"; exit 0 ;;
    */rules/branches/*)
      printf '%s\n' "${STUB_RULES_JSON:-$rules_default}"; exit 0 ;;
    */issues/*/events)
      allargs="$*"; n="${allargs%/events}"; n="${n##*/}"
      default_ev="[{\"event\":\"labeled\",\"label\":{\"name\":\"${STUB_ISSUE_LABEL:-ready-for-agent}\"},\"actor\":{\"login\":\"trusted\"}}]"
      ev="$(pick EVENTS_JSON "$n")"
      printf '%s\n' "${ev:-$default_ev}"; exit 0 ;;
    */issues/*)
      allargs="$*"; n="${allargs##*/}"
      aa="$(pick AUTHOR_ASSOC "$n")"
      printf '{"author_association":"%s"}\n' "${aa:-OWNER}"; exit 0 ;;
  esac
fi
exit 0
EOF
  } > "$STUB_DIR/gh"
  chmod +x "$STUB_DIR/gh"

  # ---- GitHub App token minter ($GRID_APP_TOKEN_BIN) ----
  {
    printf '%s\n' '#!/bin/bash'
    printf '. %s\n' "$lib"
    cat <<'EOF'
log="${STUB_MINT_LOG:-/dev/null}"
echo "mint $*" >> "$log"
count="$(wc -l < "$log" | tr -d ' ')"
if [ "${STUB_APP_MINT_FAIL:-0}" = 1 ] || { [ -n "${STUB_APP_MINT_FAIL_AFTER:-}" ] && [ "$count" -gt "$STUB_APP_MINT_FAIL_AFTER" ]; }; then
  echo "gh-app-token: stub mint failure" >&2
  exit 1
fi
if [ "${STUB_APP_TOKEN_SEQ:-0}" = 1 ]; then tok="tok$count"; else tok="${STUB_APP_TOKEN:-abc}"; fi
default_perms='{"contents":"write","pull_requests":"write","issues":"write","metadata":"read"}'
printf '{"token":"%s","permissions":%s}\n' "$tok" "${STUB_APP_PERMS:-$default_perms}"
EOF
  } > "$STUB_DIR/mint-token"
  chmod +x "$STUB_DIR/mint-token"
  export GRID_APP_TOKEN_BIN="$STUB_DIR/mint-token"

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
while [ "${1:-}" = "-k" ] || [ "${1:-}" = "--kill-after" ]; do
  shift 2
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

  # ---- curl (GitHub App token endpoints only) ----
  {
    printf '%s\n' '#!/bin/bash'
    printf '. %s\n' "$lib"
    cat <<'EOF'
stub_log curl "$@"
out=""; fmt=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -w) fmt="$2"; shift 2 ;;
    -X|-H|-d|--data|--max-time) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
tok_default='{"token":"ghs_FAKE_TOKEN_123","expires_at":"2099-01-01T00:00:00Z","permissions":{"contents":"write","pull_requests":"write","issues":"write","metadata":"read"},"repository_selection":"selected"}'
inst_default='[{"id":4242}]'
case "$url" in
  */access_tokens)
    body="${STUB_TOKEN_JSON:-$tok_default}"; code="${STUB_TOKEN_CODE:-201}" ;;
  */app/installations)
    body="${STUB_INSTALLATIONS_JSON:-$inst_default}"; code="${STUB_INSTALLATIONS_CODE:-200}" ;;
  *) body='{}'; code=404 ;;
esac
if [ -n "$out" ]; then printf '%s' "$body" > "$out"; else printf '%s' "$body"; fi
case "$fmt" in *http_code*) printf '%s' "$code" ;; esac
exit 0
EOF
  } > "$STUB_DIR/curl"
  chmod +x "$STUB_DIR/curl"

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
  jq -n --arg t "$title" --arg b "$body" --argjson l "[${labels}]" '{title:$t,body:$b,labels:$l}' > "$STUB_DIR/issue-$n.json"
}

clean_stubs() {
  if [ -n "${STUB_DIR:-}" ]; then rm -rf "$STUB_DIR"; fi
  unset STUB_DIR STUB_LOG STUB_ENV_LOG STUB_COMMENTS STUB_MINT_LOG GRID_CLAUDE GRID_APP_TOKEN_BIN
}
