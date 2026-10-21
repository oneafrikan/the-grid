#!/usr/bin/env bash
# epistemic-stop-probe.sh — observe what Claude Code's Stop hook really does, so the
# epistemic-enforcement Stop hook (openspec/changes/epistemic-enforcement, task 3.1,
# Decided 10) is written from facts, not guesses.
#
# Three facts are UNVERIFIED in this repo and this script checks each one:
#   (a) the Stop payload's field names: stop_hook_active, transcript_path, and whether
#       the payload carries the last assistant message itself;
#   (b) exit code 2 from a Stop hook feeds its stderr to the model and the turn CONTINUES;
#   (c) the second Stop payload of that turn has stop_hook_active: true.
#
# Usage:
#   bash scripts/epistemic-stop-probe.sh          dry run: print the cap and the plan, spend nothing
#   bash scripts/epistemic-stop-probe.sh --yes    run the probe: ONE live `claude -p` call
#   bash scripts/epistemic-stop-probe.sh --help
#
# Cost guard: ONE claude call, `--model haiku --max-budget-usd 0.10`, so the intended
# worst case is USD 0.10. The cap is checked between turns, so one turn in flight can
# overshoot it, and a subscription plan may not enforce it at all. The call runs under
# timeout(1) (default 120 s; no timeout binary = the script refuses to run live).
# The cap is printed first, before anything is spent, and --yes is required to proceed.
# (0.10 is the same per-call cap scripts/auto-handoff-preflight.sh uses. It was NOT lowered
# further because a cap too small to cover the Stop-hook continuation turn would make
# the run INCONCLUSIVE and waste the spend.)
#
# Safety: the probe runs in a throwaway scratch dir (mktemp -d, removed on exit, never this
# repo) with `--tools ""` (the model gets no tools, so there is nothing to approve),
# `--setting-sources project` (only the scratch project's settings.json loads: none of your
# own hooks run or interfere) and no MCP servers. Nothing under ~/.claude is written by this
# script (the CLI itself keeps its usual session transcript there, which the probe needs:
# transcript_path must point at a real file). No environment dump is taken.
#
# Result: the raw captured JSON (stop-N.json, claude-result.json) and the verdict go to
#   ${GRID_STATE_DIR:-~/.grid}/probes/epistemic-stop-<timestamp>/   (mode 700)
# and that path is printed, so the operator can paste it into the PR / issue. The captured
# payloads hold local paths and a session id (the payload's cwd, transcript_path): read
# them before pasting anywhere public.
#
# Exit codes: 0 all three PASS (or dry run) | 1 any FAIL / INCONCLUSIVE | 2 usage or a
# missing prerequisite (claude, jq, timeout, not logged in).
#
# Env:
#   GRID_CLAUDE          claude binary (default: claude on PATH); tests point it at a stub
#   GRID_STATE_DIR       where the result dir goes (default: ~/.grid)
#   GRID_PROBE_TIMEOUT   wall-clock seconds for the claude call (default 120)
set -uo pipefail

PROBE_USD=0.10          # --max-budget-usd for the single call (see Cost guard above)
PROMPT='Reply with the single word DONE.'
# Marker the hook's exit-2 reason asks the model to say. The prompt asks for DONE, so a
# final reply containing AGAIN can only be a response to the stderr the hook fed back.
MARK=AGAIN
TIMEOUT_S="${GRID_PROBE_TIMEOUT:-120}"
case "$TIMEOUT_S" in ''|*[!0-9]*) echo "epistemic-stop-probe: GRID_PROBE_TIMEOUT must be whole seconds" >&2; exit 2 ;; esac
CLAUDE_NAME="${GRID_CLAUDE:-claude}"

usage() { sed -n '2,/^set -uo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

YES=0
for a in "$@"; do
  case "$a" in
    --yes) YES=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "epistemic-stop-probe: unknown argument: $a (see --help)" >&2; exit 2 ;;
  esac
done

# ---- the cap comes first: nothing below spends or writes anything before this prints -----
echo "WORST-CASE SPEND: USD $PROBE_USD (one claude call: --model haiku --max-budget-usd $PROBE_USD, hard timeout ${TIMEOUT_S}s)."
echo "  The cap is checked between turns, so one turn in flight can overshoot it; a subscription plan may not enforce it."
echo

# ---- the plan; without --yes this is a dry run -----------------------------------------
echo "Plan:"
echo "  1. make a scratch dir; write .claude/settings.json registering one Stop hook"
echo "  2. the hook appends its raw stdin JSON to <result dir>/stop-N.json (N = call count),"
echo "     exits 2 with a one-line stderr reason on call 1 and 0 on every later call"
echo "  3. run once from the scratch dir:"
echo "       $CLAUDE_NAME -p '$PROMPT' --model haiku --max-budget-usd $PROBE_USD --output-format json"
echo "         --tools '' --permission-mode default --setting-sources project --strict-mcp-config --disable-slash-commands"
echo "  4. report (a) payload fields, (b) exit 2 continued the turn with the stderr reason, (c) second stop has stop_hook_active: true"
echo "  5. write the captured JSON and verdict to \${GRID_STATE_DIR:-~/.grid}/probes/epistemic-stop-<timestamp>/ (mode 700)"
echo
if [ "$YES" != 1 ]; then
  echo "Dry run: nothing spent, nothing written. Re-run with --yes to proceed."
  exit 0
fi

# ---- prerequisites (exit 2; checked only now so a dry run needs nothing installed) ------
CLAUDE_BIN="$(command -v "$CLAUDE_NAME" 2>/dev/null || true)"
[ -n "$CLAUDE_BIN" ] || { echo "epistemic-stop-probe: claude not found ($CLAUDE_NAME): install it or set GRID_CLAUDE" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "epistemic-stop-probe: jq not found: install jq" >&2; exit 2; }
# No timeout binary = no hard cap on wall-clock time, so refuse rather than run uncapped.
TIMEOUT_BIN="$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)"
[ -n "$TIMEOUT_BIN" ] || { echo "epistemic-stop-probe: timeout(1) not found (macOS: brew install coreutils for gtimeout); refusing to run uncapped" >&2; exit 2; }
# Logged-in check, same as automation-factory/patterns/issue-loop/run-issue.sh: `auth status
# --json` carries .loggedIn and exits non-zero when logged out. Not a model call.
_auth="$("$CLAUDE_BIN" auth status --json 2>/dev/null < /dev/null || true)"
printf '%s' "$_auth" | jq -e '.loggedIn == true' >/dev/null 2>&1 \
  || { echo "epistemic-stop-probe: claude is not logged in; run 'claude auth login'" >&2; exit 2; }

# ---- scratch + result dirs -------------------------------------------------------------
SCRATCH=""
CLAUDE_PID=""
cleanup() { [ -z "$SCRATCH" ] || rm -rf "$SCRATCH"; }
# A signal stops the claude call THIS script started (never pkill by name); the EXIT trap
# then removes the scratch dir. The call runs in the background and is waited for, so bash
# runs this handler at once instead of after the call finishes.
on_signal() {
  if [ -n "$CLAUDE_PID" ]; then kill -TERM "$CLAUDE_PID" 2>/dev/null; wait "$CLAUDE_PID" 2>/dev/null; fi
  exit "$1"
}
trap cleanup EXIT
trap 'on_signal 130' INT
trap 'on_signal 143' TERM

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/grid-stop-probe.XXXXXX")" || exit 2
SCRATCH="$(cd "$SCRATCH" && pwd -P)"   # physical path, since it is embedded in settings.json
# The result dir: umask 077 so every dir this creates is mode 700 (and files 600); the
# explicit chmod covers a pre-existing dir. Timestamp to the second plus the pid keeps two
# runs in one second apart.
STATE="${GRID_STATE_DIR:-$HOME/.grid}"
OUT="$STATE/probes/epistemic-stop-$(date +%Y%m%dT%H%M%S)-$$"
( umask 077 && mkdir -p "$OUT" ) || { echo "epistemic-stop-probe: cannot create $OUT" >&2; exit 2; }
chmod 700 "$OUT"
OUT="$(cd "$OUT" && pwd -P)"
# Both paths are embedded unescaped in the hook script and settings.json: keep them boring.
for p in "$SCRATCH" "$OUT"; do
  case "$p" in
    *[!A-Za-z0-9_./+-]*) echo "epistemic-stop-probe: path has unsupported characters: $p (set TMPDIR / GRID_STATE_DIR to a plainer path)" >&2; exit 2 ;;
  esac
done

# say: print a line and keep it in verdict.txt, so the file is the same text the operator saw.
VERDICT_FILE="$OUT/verdict.txt"
say() { printf '%s\n' "$*" | tee -a "$VERDICT_FILE"; }

# ---- the Stop hook under test -----------------------------------------------------------
# Deliberately tiny and dependency-free (plain sh): it must not shape what it observes.
# The counter lives in $OUT so one file records how many times Stop fired.
cat > "$SCRATCH/hook.sh" <<EOF
#!/bin/sh
out='$OUT'
n=0
[ -f "\$out/counter" ] && n=\$(cat "\$out/counter")
n=\$((n + 1))
echo "\$n" > "\$out/counter"
cat > "\$out/stop-\$n.json"
if [ "\$n" -eq 1 ]; then
  # First stop only: block with a reason the model can act on and we can recognise.
  echo "Probe reason: reply with the single word $MARK." >&2
  exit 2
fi
exit 0
EOF
chmod +x "$SCRATCH/hook.sh"
mkdir -p "$SCRATCH/.claude"
cat > "$SCRATCH/.claude/settings.json" <<EOF
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "sh '$SCRATCH/hook.sh'",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
EOF

# ---- the one live call ------------------------------------------------------------------
# No --no-session-persistence: that would stop the transcript being written and make
# transcript_path point at nothing, which is one of the facts being checked.
# No --max-turns: it is not in the CLI's --help here, so passing it could fail the run;
# the budget cap and the timeout bound the call instead.
say "Running one claude call (cap USD $PROBE_USD, timeout ${TIMEOUT_S}s) ..."
( cd "$SCRATCH" && exec "$TIMEOUT_BIN" --kill-after=5 "$TIMEOUT_S" "$CLAUDE_BIN" -p "$PROMPT" \
    --model haiku --max-budget-usd "$PROBE_USD" --output-format json --tools "" \
    --permission-mode default --setting-sources project --strict-mcp-config --disable-slash-commands ) \
  < /dev/null > "$OUT/claude-result.json" 2> "$OUT/claude-stderr.txt" &
CLAUDE_PID=$!
RC=0
wait "$CLAUDE_PID" || RC=$?
CLAUDE_PID=""
say "claude exited $RC"
say "captured stop payloads: $(find "$OUT" -maxdepth 1 -name 'stop-*.json' | wc -l | tr -d ' ')"
say

# ---- analysis ---------------------------------------------------------------------------
# short <string>: one line, control characters dropped, at most 200 chars (never more of the
# model's text than that goes to the terminal or the verdict).
short() { printf '%s' "$1" | tr -d '\000-\037' | cut -c1-200; }
# jqf <file> <filter>: jq that never fails the script; empty output on a bad file.
jqf() { jq -r "$2" "$1" 2>/dev/null || true; }
valid_json() { [ -s "$1" ] && jq -e . "$1" >/dev/null 2>&1; }

S1="$OUT/stop-1.json"; S2="$OUT/stop-2.json"
V_A=INCONCLUSIVE; V_B=INCONCLUSIVE; V_C=INCONCLUSIVE
E_A=""; E_B=""; E_C=""

# The CLI's own result (--output-format json): one object, or an array of events; take the
# result object either way. Used for (b) and for the cost line.
RESULT_TEXT=""; NUM_TURNS=""; COST=""
if valid_json "$OUT/claude-result.json"; then
  _sel='(if type == "array" then (map(select(.type == "result")) | last) else . end)'
  RESULT_TEXT="$(jqf "$OUT/claude-result.json" "$_sel | .result // \"\" | tostring")"
  NUM_TURNS="$(jqf "$OUT/claude-result.json" "$_sel | .num_turns // \"\" | tostring")"
  COST="$(jqf "$OUT/claude-result.json" "$_sel | .total_cost_usd // \"\" | tostring")"
fi

# (a) payload field names, from the FIRST Stop payload.
if [ ! -f "$S1" ]; then
  E_A="the Stop hook never ran (no stop-1.json); claude exited $RC; see claude-stderr.txt"
elif ! valid_json "$S1"; then
  V_A=FAIL; E_A="stop-1.json is not valid JSON (first 200 chars: $(short "$(cat "$S1")"))"
else
  KEYS="$(jqf "$S1" 'keys_unsorted | join(", ")')"
  HAS_ACTIVE="$(jqf "$S1" 'has("stop_hook_active")')"
  HAS_TP="$(jqf "$S1" 'has("transcript_path")')"
  # Last-message field: any top-level string field whose name mentions "message"
  # (e.g. last_assistant_message); the first such name is reported.
  MSG_FIELD="$(jqf "$S1" '[to_entries[] | select((.key | test("message")) and (.value | type == "string")) | .key] | first // ""')"
  TP_EXISTS=no
  TP="$(jqf "$S1" '.transcript_path // "" | tostring')"
  [ -n "$TP" ] && [ -f "$TP" ] && TP_EXISTS=yes
  E_A="keys: $KEYS"
  E_A="$E_A
      stop_hook_active present: $HAS_ACTIVE (value in stop 1: $(jqf "$S1" 'if has("stop_hook_active") then (.stop_hook_active | tostring) else "absent" end'))
      transcript_path present: $HAS_TP (file exists: $TP_EXISTS)"
  if [ -n "$MSG_FIELD" ]; then
    E_A="$E_A
      last-message field: $MSG_FIELD, preview: $(short "$(jqf "$S1" ".[\"$MSG_FIELD\"]")")"
  else
    E_A="$E_A
      last-message field: none (the hook must read the tail of transcript_path)"
  fi
  # PASS needs the two fields the hook design relies on. A missing last-message field is
  # not a failure: Decided 10 already falls back to the transcript tail.
  if [ "$HAS_ACTIVE" = true ] && [ "$HAS_TP" = true ]; then V_A=PASS; else V_A=FAIL; fi
fi

# (b) exit 2 continued the turn and the stderr reason reached the model.
if [ ! -f "$S1" ]; then
  E_B="the Stop hook never ran, so exit-2 behaviour was not observed"
elif [ ! -f "$S2" ]; then
  V_B=FAIL
  E_B="stop-1 exited 2 but there is no second Stop invocation: the turn did not continue (num_turns: ${NUM_TURNS:-unknown}; claude exited $RC)"
else
  E_B="a second Stop invocation exists (the turn continued); num_turns: ${NUM_TURNS:-unknown}"
  case "$RESULT_TEXT" in
    *"$MARK"*)
      V_B=PASS
      E_B="$E_B
      final reply contains '$MARK' (asked for only by the hook's stderr reason): $(short "$RESULT_TEXT")" ;;
    *)
      V_B=FAIL
      E_B="$E_B
      but the final reply lacks '$MARK', so the stderr reason may not have reached the model: $(short "$RESULT_TEXT")" ;;
  esac
fi

# (c) the second payload says stop_hook_active: true (and the first did not).
if [ ! -f "$S1" ]; then
  E_C="the Stop hook never ran"
elif [ ! -f "$S2" ]; then
  E_C="no second Stop payload to inspect"
elif ! valid_json "$S2"; then
  V_C=FAIL; E_C="stop-2.json is not valid JSON (first 200 chars: $(short "$(cat "$S2")"))"
else
  A1="$(jqf "$S1" 'if has("stop_hook_active") then (.stop_hook_active | tostring) else "absent" end')"
  A2="$(jqf "$S2" 'if has("stop_hook_active") then (.stop_hook_active | tostring) else "absent" end')"
  E_C="stop_hook_active: stop 1 = $A1, stop 2 = $A2"
  if [ "$A2" = true ]; then V_C=PASS; else V_C=FAIL; fi
fi

say "Verdict"
say "  (a) payload fields:           $V_A"
say "      $E_A"
say "  (b) exit 2 continues turn:    $V_B"
say "      $E_B"
say "  (c) stop 2 stop_hook_active:  $V_C"
say "      $E_C"
say
[ -z "$COST" ] || say "cost reported by the CLI: USD $COST (cap USD $PROBE_USD)"
if [ ! -f "$S1" ]; then
  say "claude stderr tail:"
  tail -n 5 "$OUT/claude-stderr.txt" 2>/dev/null | cut -c1-200 | sed 's/^/        | /' | tee -a "$VERDICT_FILE"
fi
say "Captured JSON and verdict: $OUT"
say "(payloads hold local paths and a session id: read before pasting into a public issue)"

if [ "$V_A" = PASS ] && [ "$V_B" = PASS ] && [ "$V_C" = PASS ]; then
  say "RESULT: all three PASS"
  exit 0
fi
say "RESULT: not all PASS: do not write epistemic-stop.sh on these assumptions (tasks.md 3.1)"
exit 1
