#!/usr/bin/env bash
# auto-handoff-preflight.sh — run the live checks that gate the auto-handoff hook, report
# PASS/FAIL per check, and (only when every check passes and you ask) switch the hook on.
#
# Why: the hook runs `claude -p` unattended at the end of every qualifying session. The code
# side is tested with a stub claude; four facts about the REAL claude can only be observed
# live. This script runs those probes in one go instead of by hand.
#
# Usage:
#   bash scripts/auto-handoff-preflight.sh [--check]     run the checks (default); read-only
#   bash scripts/auto-handoff-preflight.sh --enable      checks must pass in the same run, then
#                                                        drop `-hook:auto-handoff` from this
#                                                        machine's overlay and run wire.sh
#   bash scripts/auto-handoff-preflight.sh --disable     put the line back and run wire.sh
#                                                        (no live check; the safe direction)
#   --accept-env-risk      --enable only: needed when the env probe says PROPAGATES
#   --accept-dotfile-risk  --enable only: needed when a watched dotfile is a symlink or
#                          ~/.bash_aliases is writable (H-02 VS1/VS2); --check only warns
#   --dry-run           print the commands and planned edits; no claude call, no file change
#   --help
#
# The checks (one result line each, then a verdict; exit 0 only if all pass):
#   env-propagation  (R02.sec.F1) does a project .claude/settings.json `env` block reach hook
#                    subprocesses? Reported as PROPAGATES / DOES-NOT-PROPAGATE; neither fails
#                    the check, but PROPAGATES prints a WARN and makes --enable demand
#                    --accept-env-risk. The answer rests on the SessionEnd hook (the event
#                    auto-handoff uses): if it does not fire within GRID_PREFLIGHT_HOOK_WAIT
#                    seconds the result is INCONCLUSIVE = FAIL.
#   b1-rule-form     the path-scoped write rules the worker relies on are enforced: an
#                    `Edit(//abs/**)` allow is honoured for Write, a write outside it is not
#                    done, `Edit(**/.git/**)` deny holds, and `Bash(ls:*)` does not accept `>`.
#                    A denied write only counts as "blocked" when the stream-json output shows
#                    the model ATTEMPTED it; otherwise the result is INCONCLUSIVE = FAIL.
#   wp016-parity     the real claude accepts `--permission-mode default --setting-sources user
#                    --strict-mcp-config` (named in --help, and one tiny capped call works).
#   env-i-auth       the worker's minimal invocation authenticates under `env -i`. If it
#                    fails while the plain run works, the remedy is
#                    GRID_AUTOHANDOFF_KEEP_ENV=ANTHROPIC_API_KEY.
# Also reported, never failing: the manifest state of the hook, symlinked watched dotfiles
# (H-02 VS1), a writable ~/.bash_aliases (H-02 VS2), and the user's permission defaults.
#
# Cost guard: 5 live claude calls, each `--max-budget-usd 0.10 --model haiku`, so at most
# USD 0.50 (the cap may not bind on a subscription plan). The cap is printed first. Every
# claude call, `claude --help` included, runs under timeout(1); without it the checks still
# run (with a WARN) but --enable refuses. SIGINT/SIGTERM stop only the probe this script
# started and remove the scratch dir.
#
# Safety: probes run in scratch dirs under $TMPDIR, removed on exit. Nothing under
# ~/.claude is written by this script; --enable/--disable edit machines/<host>.txt only
# (a backup goes to ${GRID_STATE_DIR:-~/.grid}/preflight-backups first; the write is a
# rename of a temp file from the same directory; a symlinked or read-only overlay is
# refused) and then call wire.sh, which does the wiring.
#
# Env:
#   GRID_DIR                repo root (default: parent of scripts/)
#   GRID_HOST               machine key for the overlay (default: hostname -s)
#   GRID_BASELINE           baseline manifest (default: $GRID_DIR/baseline-submodules.txt)
#   GRID_STATE_DIR          where overlay backups go (default: ~/.grid)
#   GRID_PREFLIGHT_CLAUDE   claude binary to probe (default: claude on PATH); used by tests
#   GRID_PREFLIGHT_TIMEOUT  wall-clock seconds per claude call (default 180)
#   GRID_PREFLIGHT_TIMEOUT_BIN  timeout(1) to use (default: timeout, else gtimeout); used by tests
#   GRID_PREFLIGHT_HOOK_WAIT    seconds to wait for the SessionEnd hook marker (default 10)
#   GRID_AUTOHANDOFF_KEEP_ENV  honoured by the env -i probe exactly as the worker honours it
set -uo pipefail

GRID_DIR="${GRID_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
GRID_HOST="${GRID_HOST:-$(hostname -s 2>/dev/null || uname -n 2>/dev/null | cut -d. -f1 || echo unknown)}"
# GRID_HOST names a file (machines/<host>.txt): one safe path component, same rule as wire.sh.
if ! [[ "$GRID_HOST" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ ]]; then
  echo "preflight: GRID_HOST is not a valid machine key (letters, digits, _ . -; not starting with . or -)" >&2
  exit 2
fi
BASELINE="${GRID_BASELINE:-$GRID_DIR/baseline-submodules.txt}"
export GRID_DIR GRID_HOST
export GRID_BASELINE="$BASELINE"
HOST_FILE="$GRID_DIR/machines/$GRID_HOST.txt"
LOCAL_FILE="$GRID_DIR/machines/$GRID_HOST.local.txt"
BACKUP_DIR="${GRID_STATE_DIR:-$HOME/.grid}/preflight-backups"

PROBE_USD=0.10        # per-call budget cap, passed as --max-budget-usd to every probe
N_LIVE=5              # live claude calls in a full run: env, b1 x2, flags, auth
TIMEOUT_S="${GRID_PREFLIGHT_TIMEOUT:-180}"
case "$TIMEOUT_S" in ''|*[!0-9]*) echo "preflight: GRID_PREFLIGHT_TIMEOUT must be whole seconds" >&2; exit 2 ;; esac
HOOK_WAIT="${GRID_PREFLIGHT_HOOK_WAIT:-10}"
case "$HOOK_WAIT" in ''|*[!0-9]*) echo "preflight: GRID_PREFLIGHT_HOOK_WAIT must be whole seconds" >&2; exit 2 ;; esac
HOOK="auto-handoff"

MODE=check; DRY=0; ACCEPT_ENV_RISK=0; ACCEPT_DOTFILE_RISK=0; MODE_SET=0
usage() { sed -n '2,/^set -uo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }
for a in "$@"; do
  case "$a" in
    --check|--enable|--disable)
      [ "$MODE_SET" = 0 ] || { echo "preflight: pick one of --check, --enable, --disable" >&2; exit 2; }
      MODE="${a#--}"; MODE_SET=1 ;;
    --dry-run) DRY=1 ;;
    --accept-env-risk) ACCEPT_ENV_RISK=1 ;;
    --accept-dotfile-risk) ACCEPT_DOTFILE_RISK=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "preflight: unknown argument: $a (see --help)" >&2; exit 2 ;;
  esac
done

# ---- output helpers -------------------------------------------------------------------
FAILS=0
pass() { printf 'PASS  %-16s %s\n' "$1" "$2"; }
fail() { printf 'FAIL  %-16s %s\n' "$1" "$2"; FAILS=$((FAILS + 1)); }
skip() { printf 'SKIP  %-16s %s\n' "$1" "$2"; }
warn() { printf 'WARN  %s\n' "$*"; }
info() { printf 'INFO  %s\n' "$*"; }
more() { printf '        %s\n' "$*"; }
# indented tail of a probe's captured output (last lines only, cut to a sane width)
show_tail() { [ -s "$1" ] && tail -n 5 "$1" | cut -c1-200 | sed 's/^/        | /'; return 0; }

# ---- scratch space --------------------------------------------------------------------
SCRATCH_ROOT=""
TMP_FILES=()        # temp files (overlay copies) to remove on exit
PROBE_PID=""        # pid of the claude probe this script has running, if any
cleanup() {
  [ -z "$SCRATCH_ROOT" ] || rm -rf "$SCRATCH_ROOT"
  [ "${#TMP_FILES[@]}" -eq 0 ] || rm -f "${TMP_FILES[@]}"
}
# A signal stops the probe THIS script started (nothing else: no pkill by name), then exits;
# the EXIT trap removes the scratch dir. The probe runs in the background and is waited for
# with `wait`, so bash runs this handler at once instead of after the probe finishes.
on_signal() {
  if [ -n "$PROBE_PID" ]; then
    kill -TERM "$PROBE_PID" 2> /dev/null
    wait "$PROBE_PID" 2> /dev/null
  fi
  exit "$1"
}
trap cleanup EXIT
trap 'on_signal 130' INT
trap 'on_signal 143' TERM
# init_scratch: the one temp root for this run. Called from main, NOT from scratch(): scratch
# runs inside $(...), and a variable set in that subshell would never reach the EXIT trap.
init_scratch() {
  SCRATCH_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/grid-preflight.XXXXXX")" || exit 1
  SCRATCH_ROOT="$(cd "$SCRATCH_ROOT" && pwd -P)"   # physical path: rules must name the real dir
}
# scratch <name>: a fresh dir for one probe (a placeholder path in --dry-run: nothing is created).
scratch() {
  if [ "$DRY" = 1 ]; then printf '<scratch>/%s' "$1"; return 0; fi
  mkdir -p "$SCRATCH_ROOT/$1" && printf '%s' "$SCRATCH_ROOT/$1"
}
# The probe settings.json and the rule strings embed the path unescaped, so keep it boring.
safe_path() { [[ "$1" =~ ^[A-Za-z0-9_./+-]+$ ]]; }

# ---- running claude -------------------------------------------------------------------
CLAUDE_NAME="${GRID_PREFLIGHT_CLAUDE:-claude}"
CLAUDE_BIN="$(command -v "$CLAUDE_NAME" 2>/dev/null || true)"
if [ -n "${GRID_PREFLIGHT_TIMEOUT_BIN:-}" ]; then
  TIMEOUT_BIN="$(command -v "$GRID_PREFLIGHT_TIMEOUT_BIN" 2>/dev/null || true)"
else
  TIMEOUT_BIN="$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)"
fi
have_claude() { [ "$DRY" = 1 ] || [ -n "$CLAUDE_BIN" ]; }
no_claude() { fail "$1" "claude not found ($CLAUDE_NAME): install it or set GRID_PREFLIGHT_CLAUDE"; }
# rc_desc <rc>: how a probe ended, in words (124 = timeout(1) fired, 137 = it had to KILL)
rc_desc() { case "$1" in 124|137) printf 'timed out after %ss' "$TIMEOUT_S" ;; *) printf 'exited %s' "$1" ;; esac; }

PROBE_RC=0
# probe <env-i 0|1> <cwd> <out file> <claude args...>: one capped claude call; exit status in
# PROBE_RC, stdout+stderr in the out file. GRID_AUTOHANDOFF_CHILD=1 makes any auto-handoff
# hook that is already wired return at once, so a probe never spawns a handoff of its own.
# The call runs under timeout(1) when it exists. It is started in the background with `exec`
# (so $! is the timeout or claude process itself) and waited for, which lets on_signal stop it.
probe() {
  local envi="$1" cwd="$2" out="$3"; shift 3
  PROBE_RC=0
  local to=()
  [ -z "$TIMEOUT_BIN" ] || to=("$TIMEOUT_BIN" --kill-after=5 "$TIMEOUT_S")
  if [ "$DRY" = 1 ]; then
    printf '  would run: (cd %s &&' "$cwd"
    [ "$envi" = 1 ] && printf ' env -i <worker child env>' || printf ' GRID_AUTOHANDOFF_CHILD=1'
    printf ' %q' "${to[@]+"${to[@]}"}" "$CLAUDE_NAME" "$@"; printf ')\n'
    return 0
  fi
  if [ "$envi" = 1 ]; then
    ( cd "$cwd" && exec env -i "${CHILD_ENV[@]}" "${to[@]+"${to[@]}"}" "$CLAUDE_BIN" "$@" ) < /dev/null > "$out" 2>&1 &
  else
    ( cd "$cwd" && export GRID_AUTOHANDOFF_CHILD=1 && exec "${to[@]+"${to[@]}"}" "$CLAUDE_BIN" "$@" ) < /dev/null > "$out" 2>&1 &
  fi
  PROBE_PID=$!
  wait "$PROBE_PID" || PROBE_RC=$?
  PROBE_PID=""
  return 0
}

# ---- check a: env propagation (R02.sec.F1) --------------------------------------------
ENV_RESULT=""   # PROPAGATES | DOES-NOT-PROPAGATE | (empty: not determined)
check_env() {
  local n=env-propagation d nonce got f
  have_claude || { no_claude $n; return; }
  d="$(scratch env)" || { fail $n "cannot create a scratch dir"; return; }
  if [ "$DRY" = 0 ]; then
    safe_path "$d" || { fail $n "scratch path has unsupported characters: $d"; return; }
    mkdir -p "$d/.claude"
    nonce="pf$$-$(date +%s)-$RANDOM"
    # A project settings.json whose env block sets a marker, and hooks that write what they
    # see. Two events: if one does not fire under -p the other still answers. The stub in
    # the tests parses this layout (one key per line), so keep it that way.
    cat > "$d/.claude/settings.json" <<EOF
{
  "env": {
    "GRID_PREFLIGHT_MARKER": "$nonce"
  },
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "echo ran:\${GRID_PREFLIGHT_MARKER-UNSET} > '$d/start.out'"
          }
        ]
      }
    ],
    "SessionEnd": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "echo ran:\${GRID_PREFLIGHT_MARKER-UNSET} > '$d/end.out'"
          }
        ]
      }
    ]
  }
}
EOF
  fi
  # Worker flags where the semantics allow: --setting-sources user is NOT one of them, since
  # this probe exists to see what happens when the PROJECT's settings.json is loaded.
  info "probe flags (env-propagation): --permission-mode default --strict-mcp-config, without --setting-sources (the project's settings.json must load)"
  probe 0 "$d" "$d/out.txt" -p "PREFLIGHT-ENV: reply with the single word ok." \
    --model haiku --max-budget-usd "$PROBE_USD" --max-turns 2 --tools "" \
    --permission-mode default --strict-mcp-config
  [ "$DRY" = 1 ] && { skip $n "dry-run: would build a scratch project with an env block and two hooks, then read what the hooks saw"; return; }
  if [ "$PROBE_RC" -ne 0 ]; then
    fail $n "claude $(rc_desc "$PROBE_RC"); cannot tell whether env reaches hooks"; show_tail "$d/out.txt"; return
  fi
  # The answer must come from SessionEnd, the event auto-handoff runs on. It can land after
  # claude has exited, so wait for its marker (up to HOOK_WAIT seconds) before concluding.
  local i
  for ((i = 0; i < HOOK_WAIT * 4; i++)); do
    [ -f "$d/end.out" ] && break
    sleep 0.25
  done
  got=""
  for f in start.out end.out; do [ -f "$d/$f" ] && got="$got$(cat "$d/$f")"; done
  local end_got=""
  [ ! -f "$d/end.out" ] || end_got="$(cat "$d/end.out")"
  if [[ "$got" == *"ran:$nonce"* ]]; then
    # Either event seeing the marker proves a project env block reaches hooks.
    ENV_RESULT=PROPAGATES
    pass $n "PROPAGATES: a project settings.json env block reaches hook subprocesses"
    warn "auto-handoff must only run in repos you trust: a cloned repo's .claude/settings.json can"
    warn "  set GRID_HOOKS, GRID_PRIVATE_DIR, GRID_CLAUDE and GRID_AUTOHANDOFF_KEEP_ENV for the hook"
    warn "  (R02.sec.F1). --enable will require --accept-env-risk."
  elif [ -z "$end_got" ]; then
    fail $n "INCONCLUSIVE: the SessionEnd hook (the event auto-handoff uses) did not fire within ${HOOK_WAIT}s, so the question is unanswered; rerun"
  elif [[ "$end_got" == *"ran:UNSET"* ]]; then
    ENV_RESULT=DOES-NOT-PROPAGATE
    pass $n "DOES-NOT-PROPAGATE: the SessionEnd hook ran and did not see the project env block"
  else
    fail $n "INCONCLUSIVE: unexpected SessionEnd hook output: $(printf '%s' "$end_got" | head -c 120)"
  fi
}

# ---- check b: B1 rule form ------------------------------------------------------------
# Probe 1 is the operator's command (OPERATOR-TASKS B1) with the same allow/deny shape the
# worker uses. Probe 2 asks the other mechanical questions: the .git deny and whether a
# `Bash(ls:*)` allow accepts a `>` redirect. A file that is absent only proves the rule if
# the model tried, so probe 2 also asks for a file the rules DO allow (ok.txt): it is the
# positive control.
check_b1() {
  local n=b1-rule-form d d2 problems=()
  have_claude || { no_claude $n; return; }
  command -v git >/dev/null 2>&1 || { fail $n "git not found (the probes need a scratch repo)"; return; }
  d="$(scratch b1a)" && d2="$(scratch b1b)" || { fail $n "cannot create a scratch dir"; return; }
  if [ "$DRY" = 0 ]; then
    safe_path "$d" && safe_path "$d2" || { fail $n "scratch path has unsupported characters"; return; }
    mkdir -p "$d/LOGS" && git -C "$d" init -q && git -C "$d2" init -q || { fail $n "git init failed in the scratch dir"; return; }
  fi
  # All three worker flags apply here: the rules are passed on the command line, so
  # --setting-sources user (no project/local settings) costs the probe nothing.
  # --output-format stream-json --verbose prints a tool_use event for every action the model
  # attempts, blocked or not: that is the evidence an "absent" file needs.
  info "probe flags (b1-rule-form): --permission-mode default --setting-sources user --strict-mcp-config (the worker's), plus --output-format stream-json --verbose to see attempts"
  probe 0 "$d" "$d/out.txt" -p "write x to $d/outside.txt, then to $d/LOGS/inside.txt" \
    --model haiku --max-budget-usd "$PROBE_USD" --max-turns 6 --tools "Read,Write,Bash" \
    --permission-mode default --setting-sources user --strict-mcp-config \
    --output-format stream-json --verbose \
    --allowedTools "Read" "Edit(/$d/LOGS/**)" --disallowedTools "Edit" "Bash(git:*)"
  local rc1=$PROBE_RC
  probe 0 "$d2" "$d2/out.txt" -p "write x to $d2/ok.txt, then write x to $d2/.git/probe.txt, then run the Bash command: ls $d2 > $d2/redirect.txt" \
    --model haiku --max-budget-usd "$PROBE_USD" --max-turns 6 --tools "Read,Write,Bash" \
    --permission-mode default --setting-sources user --strict-mcp-config \
    --output-format stream-json --verbose \
    --allowedTools "Read" "Edit(/$d2/**)" "Bash(ls:*)" --disallowedTools "Edit(**/.git/**)" "Bash(git:*)"
  local rc2=$PROBE_RC
  [ "$DRY" = 1 ] && { skip $n "dry-run: would run two capped probes and assert on the files they leave and on the attempts they made"; return; }
  if [ "$rc1" -ne 0 ] || [ "$rc2" -ne 0 ]; then
    fail $n "claude $(rc_desc "$rc1") / $(rc_desc "$rc2") (probe 1 / probe 2); cannot judge the rules"
    show_tail "$d/out.txt"; show_tail "$d2/out.txt"; return
  fi
  # problems = a rule did not hold; unproven = a denied action was never attempted, so its
  # absence proves nothing.
  local unproven=()
  [ -f "$d/LOGS/inside.txt" ] || problems+=("inside.txt missing: Edit(//abs/**) allow was not honoured for Write")
  if [ -e "$d/outside.txt" ]; then
    problems+=("outside.txt written: a write outside the allowed dir was not blocked")
  elif ! attempted "$d/out.txt" "outside.txt"; then
    unproven+=("no evidence the model attempted the write to outside.txt, so its absence proves nothing")
  fi
  if [ ! -f "$d2/ok.txt" ]; then
    problems+=("ok.txt missing: positive control failed, so the .git and redirect results prove nothing")
  else
    if [ -e "$d2/.git/probe.txt" ]; then
      problems+=(".git/probe.txt written: Edit(**/.git/**) deny not enforced")
    elif ! attempted "$d2/out.txt" ".git/probe.txt"; then
      unproven+=("no evidence the model attempted the .git/probe.txt write, so the .git deny is unproven")
    fi
    if [ -e "$d2/redirect.txt" ]; then
      problems+=("redirect.txt written: Bash(ls:*) accepted a '>' redirect")
    elif ! attempted "$d2/out.txt" "redirect.txt"; then
      unproven+=("no evidence the model attempted the 'ls >' redirect (redirect.txt), so Bash(ls:*) is unproven")
    fi
  fi
  if [ "${#problems[@]}" -eq 0 ] && [ "${#unproven[@]}" -eq 0 ]; then
    pass $n "inside.txt present; outside.txt, .git write and 'ls >' redirect attempted and blocked"
    return
  fi
  local all=() p first=1
  [ "${#problems[@]}" -eq 0 ] || all+=("${problems[@]}")
  for p in ${unproven[@]+"${unproven[@]}"}; do all+=("INCONCLUSIVE: $p"); done
  for p in "${all[@]}"; do
    if [ "$first" = 1 ]; then fail $n "$p"; first=0; else more "$p"; fi
  done
  [ "${#unproven[@]}" -eq 0 ] || more "rerun the script (model behaviour varies); a rule is only proven when the model tried the action and it was blocked"
}
# attempted <stream-json out file> <needle>: does a tool_use event name the path/command?
# (A here-string, not a pipe: under pipefail an early-exiting grep -q can fail the pipeline.)
attempted() {
  local lines
  lines="$(grep -E '"type": ?"tool_use"' "$1" 2> /dev/null)" || return 1
  grep -q -F -- "$2" <<< "$lines"
}

# ---- check c: WP-016 flag parity ------------------------------------------------------
WP016_OK=0
check_flags() {
  local n=wp016-parity d help flag missing=()
  have_claude || { no_claude $n; return; }
  d="$(scratch flags)" || { fail $n "cannot create a scratch dir"; return; }
  # --help is a claude call like any other: same timeout, same scratch cwd.
  probe 0 "$d" "$d/help.txt" --help
  if [ "$DRY" = 0 ]; then
    if [ "$PROBE_RC" -ne 0 ]; then
      fail $n "claude --help $(rc_desc "$PROBE_RC")"; show_tail "$d/help.txt"; return
    fi
    help="$(cat "$d/help.txt")"
    for flag in --permission-mode --setting-sources --strict-mcp-config; do
      # here-string, not a pipe: under pipefail a grep -q that exits early can SIGPIPE the printf
      grep -q -F -- "$flag" <<< "$help" || missing+=("$flag")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
      fail $n "claude --help does not name: ${missing[*]}"; return
    fi
  fi
  info "probe flags (wp016-parity): --permission-mode default --setting-sources user --strict-mcp-config (the worker's)"
  probe 0 "$d" "$d/out.txt" -p "PREFLIGHT-FLAGS: reply with the single word ok." \
    --model haiku --max-budget-usd "$PROBE_USD" --max-turns 2 \
    --permission-mode default --setting-sources user --strict-mcp-config --tools "Read,Write,Bash"
  [ "$DRY" = 1 ] && { skip $n "dry-run: would also run one capped call with the worker's flags"; return; }
  if [ "$PROBE_RC" -ne 0 ]; then
    fail $n "claude $(rc_desc "$PROBE_RC") with --permission-mode default --setting-sources user --strict-mcp-config"
    show_tail "$d/out.txt"; return
  fi
  WP016_OK=1
  pass $n "--permission-mode default --setting-sources user --strict-mcp-config accepted"
}

# ---- check d: env -i auth -------------------------------------------------------------
# CHILD_ENV mirrors the worker's: the same variables, and KEEP_ENV (NAME or PREFIX*) read the
# same way, so a pass here means the worker's child will authenticate.
CHILD_ENV=()
build_child_env() {
  local pats=() pat pfx nm
  CHILD_ENV=()
  IFS=, read -r -a pats <<< "${GRID_AUTOHANDOFF_KEEP_ENV:-}"
  for pat in "${pats[@]+"${pats[@]}"}"; do
    [[ "$pat" =~ ^[A-Za-z_][A-Za-z0-9_]*\*?$ ]] || continue
    case "$pat" in
      *'*')
        pfx="${pat%\*}"
        while IFS= read -r nm; do
          [[ "$nm" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
          case "$nm" in "$pfx"*) CHILD_ENV+=("$nm=${!nm}") ;; esac
        done < <(compgen -e) ;;
      *) [ -n "${!pat+x}" ] && CHILD_ENV+=("$pat=${!pat}") ;;
    esac
  done
  for nm in LANG LC_ALL TMPDIR CLAUDE_CONFIG_DIR CLAUDE_CODE_OAUTH_TOKEN; do
    [ -n "${!nm+x}" ] && CHILD_ENV+=("$nm=${!nm}")
  done
  CHILD_ENV+=("PATH=$PATH" "HOME=$HOME" "GRID_AUTOHANDOFF_CHILD=1")
}
check_auth() {
  local n=env-i-auth d
  have_claude || { no_claude $n; return; }
  build_child_env
  d="$(scratch auth)" || { fail $n "cannot create a scratch dir"; return; }
  info "probe flags (env-i-auth): the worker's full invocation under env -i: --permission-mode default --setting-sources user --strict-mcp-config"
  probe 1 "$d" "$d/out.txt" -p "PREFLIGHT-AUTH: reply with the single word ok." \
    --model haiku --max-budget-usd "$PROBE_USD" --max-turns 2 \
    --permission-mode default --setting-sources user --strict-mcp-config --tools "Read,Write,Bash"
  [ "$DRY" = 1 ] && { skip $n "dry-run: would run the worker's invocation under env -i"; return; }
  if [ "$PROBE_RC" -eq 0 ]; then
    if [ -n "${GRID_AUTOHANDOFF_KEEP_ENV:-}" ]; then
      pass $n "authenticates under env -i (with GRID_AUTOHANDOFF_KEEP_ENV=$GRID_AUTOHANDOFF_KEEP_ENV)"
    else
      pass $n "authenticates under env -i (login/OAuth; no API-key variable needed)"
    fi
    return
  fi
  fail $n "claude $(rc_desc "$PROBE_RC") under env -i"
  show_tail "$d/out.txt"
  if [ "$WP016_OK" = 1 ] && grep -q -i -E 'auth|log ?in|api[ _-]?key|credential|unauthori[sz]ed|401|oauth|token' "$d/out.txt"; then
    more "remedy: claude works with your normal environment but not under env -i, so it"
    more "authenticates through an environment variable. In the shell that starts claude (the"
    more "hook inherits it), set:"
    more "  export GRID_AUTOHANDOFF_KEEP_ENV=ANTHROPIC_API_KEY"
    more "then rerun this script. (Note: KEEP_ENV is itself settable by a repo env block; see"
    more "the env-propagation result.)"
  fi
}

# ---- read-only reports ----------------------------------------------------------------
# layer_last <file>: "on" or "off" for the LAST hook:/-hook:auto-handoff line, empty if none.
# Reads the file the way wire.sh's load_manifest does: `while IFS= read -r line` (so a last
# line with no newline is NOT read), the trailing # comment cut, then ALL whitespace removed
# (tr -d '[:space:]': form feed and vertical tab included). If this reader and wire.sh ever
# disagree, the script could report "enabled" while wire.sh still reads the hook as OFF.
layer_last() {
  local line v=""
  [ -f "$1" ] || return 0
  while IFS= read -r line; do
    line="${line%%#*}"; line="${line//[[:space:]]/}"
    case "$line" in
      "hook:$HOOK")  v=on ;;
      "-hook:$HOOK") v=off ;;
    esac
  done < "$1"
  [ -z "$v" ] || printf '%s\n' "$v"
}
# effective_state <host file to use>: sets EFF (on|off) and EFF_SRC (the file that decided).
# Layers load baseline, host, host.local; the last one with an opinion wins; default is on.
effective_state() {
  local f v
  EFF=on; EFF_SRC="default: no manifest file says -hook:$HOOK"
  for f in "$BASELINE" "$1" "$LOCAL_FILE"; do
    v="$(layer_last "$f")"
    [ -z "$v" ] || { EFF="$v"; EFF_SRC="$f"; }
  done
}
report_state() {
  effective_state "$HOST_FILE"
  info "$HOOK manifest state: $(printf '%s' "$EFF" | tr '[:lower:]' '[:upper:]') (${EFF_SRC#"$GRID_DIR"/})"
  [ "$EFF" != off ] || info "  ($HOOK is OFF on this machine; --enable removes -hook:$HOOK from machines/$GRID_HOST.txt)"
}
DOTFILE_RISK=0   # set when a symlinked watched dotfile or a writable ~/.bash_aliases is found
report_dotfiles() {
  local f
  for f in "$HOME/.gitconfig" "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.config/git/config" "$HOME/.ssh/config"; do
    if [ -L "$f" ]; then
      DOTFILE_RISK=1
      warn "${f/#$HOME/\~} is a symlink: the worker watches these files and a link makes its before/after comparison unreliable (H-02 VS1)"
    fi
  done
  if [ -e "$HOME/.bash_aliases" ] && [ -w "$HOME/.bash_aliases" ]; then
    DOTFILE_RISK=1
    warn "\$HOME/.bash_aliases exists and is writable: .bashrc may source it, so a write there would run in every shell and the worker does not watch it (H-02 VS2). Keep it absent or read-only."
  fi
  [ "$DOTFILE_RISK" = 0 ] || warn "  --enable will require --accept-dotfile-risk."
}
# Allow rules can embed secrets (an "always allow" stores whole command prefixes), so only
# the SHAPE of each rule is printed: the tool name, with everything inside (...) masked.
report_user_permissions() {
  local s="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
  if [ ! -r "$s" ] || ! command -v python3 >/dev/null 2>&1; then
    info "user permissions: not read (no readable settings.json or no python3)"; return
  fi
  python3 -I - "$s" <<'PY' 2>/dev/null || info "user permissions: settings.json not readable as JSON"
import collections, json, re, sys
p = (json.load(open(sys.argv[1])).get("permissions") or {})
rules = p.get("allow") or []
mode = str(p.get("defaultMode", "(unset)"))
if not re.match(r"^[A-Za-z()]{1,24}$", mode):
    mode = "***"
def shape(r):
    m = re.match(r"^([A-Za-z_][A-Za-z0-9_.:-]{0,39})(\(.*\))?$", str(r), re.S)
    if not m:
        return "***"
    return m.group(1) + ("(***)" if m.group(2) else "")
shapes = collections.Counter(shape(r) for r in rules)
print("INFO  user permissions: defaultMode=%s, %d allow rule(s), values masked" % (mode, len(rules)))
for k, n in sorted(shapes.items())[:20]:
    print("        allow: %s%s" % (k, " x%d" % n if n > 1 else ""))
print("INFO  not asserted here: whether --setting-sources user inherits those allow rules (the worker passes its own)")
PY
}

run_checks() {
  report_state
  report_dotfiles
  report_user_permissions
  check_env
  check_b1
  check_flags
  check_auth
}

# ---- overlay edits (--enable / --disable) ---------------------------------------------
BACKUP_FILE=""
backup_overlay() {
  [ -f "$HOST_FILE" ] || return 0
  mkdir -p "$BACKUP_DIR" || return 1
  BACKUP_FILE="$BACKUP_DIR/$GRID_HOST.txt.$(date -u +%Y%m%dT%H%M%SZ).$$"
  cp -p "$HOST_FILE" "$BACKUP_FILE" || { BACKUP_FILE=""; return 1; }
}
# strip_off_lines <file>: copy the file to stdout minus every -hook:auto-handoff line,
# counting them in REMOVED. Same reader as layer_last; everything else is kept byte for
# byte (CRLF, comments), and an unterminated last line is kept as it is.
# Call it directly (not in $(...)): REMOVED must survive.
REMOVED=0
strip_off_lines() {
  local line s
  REMOVED=0
  while IFS= read -r line; do
    s="${line%%#*}"; s="${s//[[:space:]]/}"
    if [ "$s" = "-hook:$HOOK" ]; then REMOVED=$((REMOVED + 1)); else printf '%s\n' "$line"; fi
  done < "$1"
  [ -z "$line" ] || printf '%s' "$line"
}
# overlay_editable: refuse to edit a symlinked or read-only overlay (message on stdout).
# A symlink is refused rather than followed: the edit would land somewhere other than
# machines/<host>.txt. A read-only file is the operator's lock; a rename would bypass it.
overlay_editable() {
  if [ -L "$HOST_FILE" ]; then
    echo "refused: machines/$GRID_HOST.txt is a symlink; edit its target by hand. Nothing was changed."; return 1
  fi
  if [ -e "$HOST_FILE" ] && [ ! -w "$HOST_FILE" ]; then
    echo "refused: machines/$GRID_HOST.txt is not writable. Nothing was changed."; return 1
  fi
}
# write_overlay <content file>: replace the overlay atomically. The new content goes to a
# temp file in the SAME directory (keeping the old file's mode) and is renamed over the
# overlay, so an interrupt leaves the old file or the new one, never half of either. Every
# step is checked; on failure nothing is changed and the caller says nothing succeeded.
write_overlay() {
  local dir new mode
  dir="$(dirname "$HOST_FILE")"
  new="$(mktemp "$dir/$GRID_HOST.txt.preflight.XXXXXX" 2>&1)" || { echo "preflight: cannot write in $dir: $new" >&2; return 1; }
  TMP_FILES+=("$new")
  if [ -f "$HOST_FILE" ]; then
    cp -p "$HOST_FILE" "$new" || { echo "preflight: cannot copy $HOST_FILE" >&2; return 1; }
  else
    mode="$(printf '%03o' $((0666 & ~$(umask))))"
    chmod "$mode" "$new" || return 1
  fi
  cat "$1" > "$new" || { echo "preflight: cannot write $new" >&2; return 1; }
  mv -f "$new" "$HOST_FILE" || { echo "preflight: cannot replace $HOST_FILE" >&2; return 1; }
}
# edit_overlay <content file>: back up, then write; a failed write removes the backup so a
# failure changes nothing at all.
edit_overlay() {
  backup_overlay || { echo "preflight: could not back up $HOST_FILE; nothing changed" >&2; return 1; }
  if ! write_overlay "$1"; then
    [ -z "$BACKUP_FILE" ] || rm -f "$BACKUP_FILE"
    BACKUP_FILE=""
    echo "preflight: the overlay was not changed." >&2
    return 1
  fi
}
run_wire() {
  echo "running: bash $GRID_DIR/scripts/wire.sh"
  # GRID_DIR, GRID_HOST and GRID_BASELINE are exported above, so wire.sh reads the same
  # overlay files this script just edited.
  if ! bash "$GRID_DIR/scripts/wire.sh"; then
    echo "preflight: wire.sh failed (the overlay edit above is already in place)." >&2
    return 1
  fi
}
undo_hint() {
  echo "To undo: bash scripts/auto-handoff-preflight.sh --disable (re-adds -hook:$HOOK to machines/$GRID_HOST.txt and runs wire.sh)."
  [ -z "${BACKUP_FILE:-}" ] || echo "The overlay as it was before: $BACKUP_FILE"
}

do_enable() {
  local tmp removed
  if [ "$DRY" = 1 ]; then
    echo "dry-run: after all checks pass (and --accept-env-risk if env PROPAGATES) --enable would:"
    echo "  - copy $HOST_FILE to $BACKUP_DIR/ (only if a -hook:$HOOK line has to go)"
    echo "  - remove every -hook:$HOOK line from $HOST_FILE"
    echo "  - run: bash $GRID_DIR/scripts/wire.sh"
    return 0
  fi
  if [ "$FAILS" -gt 0 ]; then
    echo "enable refused: $FAILS check(s) failed. Nothing was changed."; return 1
  fi
  if [ "$ENV_RESULT" = PROPAGATES ] && [ "$ACCEPT_ENV_RISK" = 0 ]; then
    echo "enable refused: project env blocks reach hooks (see the WARN above). If you only run"
    echo "claude in repos you trust, rerun with --accept-env-risk. Nothing was changed."; return 1
  fi
  if [ -z "$TIMEOUT_BIN" ]; then
    echo "enable refused: no timeout(1) on PATH, so the probes ran without a wall-clock limit and a"
    echo "hung claude would not have been caught. Install coreutils timeout and rerun. Nothing was changed."; return 1
  fi
  if [ "$DOTFILE_RISK" = 1 ] && [ "$ACCEPT_DOTFILE_RISK" = 0 ]; then
    echo "enable refused: a watched dotfile is a symlink or ~/.bash_aliases is writable (see the WARN"
    echo "above; H-02 VS1/VS2). Fix that, or rerun with --accept-dotfile-risk. Nothing was changed."; return 1
  fi
  overlay_editable || return 1
  tmp="$(mktemp "${TMPDIR:-/tmp}/grid-preflight-overlay.XXXXXX")" || return 1
  TMP_FILES+=("$tmp")
  [ ! -f "$HOST_FILE" ] || strip_off_lines "$HOST_FILE" > "$tmp"
  # The edit must actually turn the hook on: a -hook line in the baseline or the .local
  # overlay would still win, and this script does not edit those files.
  effective_state "$tmp"
  if [ "$EFF" = off ]; then
    echo "enable refused: -hook:$HOOK is also set in ${EFF_SRC#"$GRID_DIR"/}, which this script does not edit."
    echo "Remove it there first. Nothing was changed."; return 1
  fi
  if [ -f "$HOST_FILE" ] && [ "$REMOVED" -gt 0 ]; then
    removed="$REMOVED"
    edit_overlay "$tmp" || return 1
    # said only after the write succeeded
    echo "removed $removed -hook:$HOOK line(s) from machines/$GRID_HOST.txt"
  else
    echo "nothing to change in machines/$GRID_HOST.txt (no -hook:$HOOK line)"
  fi
  # wire.sh is idempotent and rerun even when the overlay needed no edit: the manifest
  # saying ON does not prove the hook entry is in settings.json.
  if ! run_wire; then undo_hint; return 1; fi
  echo "$HOOK is enabled on $GRID_HOST. Watch the first handoffs: tail \${GRID_HOOK_LOG_DIR:-\$HOME/.grid/hook-logs}/auto-handoff.log"
  undo_hint
}

do_disable() {
  if [ "$DRY" = 1 ]; then
    echo "dry-run: --disable would append -hook:$HOOK to $HOST_FILE (backup first, only if it changes) and run: bash $GRID_DIR/scripts/wire.sh"
    return 0
  fi
  overlay_editable || return 1
  if [ "$(layer_last "$HOST_FILE")" = off ]; then
    echo "nothing to change in machines/$GRID_HOST.txt (already ends with -hook:$HOOK)"
  else
    local tmp
    mkdir -p "$(dirname "$HOST_FILE")" || { echo "preflight: cannot create machines/; nothing changed" >&2; return 1; }
    tmp="$(mktemp "${TMPDIR:-/tmp}/grid-preflight-overlay.XXXXXX")" || return 1
    TMP_FILES+=("$tmp")
    [ ! -f "$HOST_FILE" ] || cat "$HOST_FILE" > "$tmp"
    # A file that does not end in a newline would glue the new line onto its last entry.
    if [ -s "$tmp" ] && [ "$(tail -c1 "$tmp" | wc -l | tr -d ' ')" -eq 0 ]; then printf '\n' >> "$tmp"; fi
    printf -- '-hook:%s   # added by auto-handoff-preflight.sh --disable\n' "$HOOK" >> "$tmp"
    edit_overlay "$tmp" || return 1
    echo "added -hook:$HOOK to machines/$GRID_HOST.txt"
  fi
  run_wire || return 1
  echo "$HOOK is disabled on $GRID_HOST. Re-enable: bash scripts/auto-handoff-preflight.sh --enable"
  [ -z "${BACKUP_FILE:-}" ] || echo "The overlay as it was before: $BACKUP_FILE"
}

# ---- main -----------------------------------------------------------------------------
cap_total="$(awk -v n="$N_LIVE" -v u="$PROBE_USD" 'BEGIN { printf "%.2f", n * u }')"
dry_note=""; [ "$DRY" = 0 ] || dry_note=" (dry-run)"
echo "auto-handoff preflight: mode=$MODE$dry_note host=$GRID_HOST"
[ "$MODE" = disable ] || \
  echo "live spend cap: $N_LIVE claude calls, each --max-budget-usd $PROBE_USD on the cheapest model = at most USD $cap_total (a subscription plan may not enforce the cap)"

case "$MODE" in
  disable) do_disable; exit $? ;;
esac
[ -n "$TIMEOUT_BIN" ] || \
  warn "no timeout(1) found: claude calls are not wall-clock limited (the per-call USD cap still applies) and --enable will refuse. Install coreutils timeout."

[ "$DRY" = 1 ] || init_scratch
run_checks
echo
if [ "$DRY" = 1 ]; then
  echo "VERDICT: not run (dry-run)"
elif [ "$FAILS" -eq 0 ]; then
  echo "VERDICT: PASS (4/4 checks)"
else
  echo "VERDICT: FAIL ($FAILS of 4 checks failed)"
fi

if [ "$MODE" = enable ]; then
  echo
  do_enable; exit $?
fi
[ "$DRY" = 1 ] && exit 0
[ "$FAILS" -eq 0 ]
