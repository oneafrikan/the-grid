#!/usr/bin/env bash
# run-record.sh — append one line to the grid run log: what an agent run did, to what, with what outcome.
#
# Why: the grid keeps no per-run record (eval finding #6), so there is nothing to review
# when a role misbehaves. This is the smallest useful record: one JSON object per run,
# appended to a local file. Unattended roles write one line per run (see the role's Hard rules);
# a retro (docs/agent-retro.md) starts from these lines.
#
# Usage:
#   run-record.sh --role gh-triage --action classify --outcome ok [--target owner/repo#212]
#                 [--operator NAME] [--cost-usd 0.02] [--note "free text, max 500 chars"]
#   outcome is one of: ok | error | stopped | skipped
#
# The log is local and private to the machine: ${GRID_RUN_LOG:-$HOME/.the-grid-private/runs.jsonl}
# (directory 0700, file 0600). Nothing here sends the record anywhere.
# Operator = who started the run (--operator, else $GRID_OPERATOR, else $USER); role = which
# agent persona acted. They are different things and both are recorded.
set -euo pipefail

role="" action="" outcome="" target="" operator="${GRID_OPERATOR:-${USER:-unknown}}" cost="" note=""

die() { echo "run-record: $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --role)      role="${2:-}";     shift 2 ;;
    --action)    action="${2:-}";   shift 2 ;;
    --outcome)   outcome="${2:-}";  shift 2 ;;
    --target)    target="${2:-}";   shift 2 ;;
    --operator)  operator="${2:-}"; shift 2 ;;
    --cost-usd)  cost="${2:-}";     shift 2 ;;
    --note)      note="${2:-}";     shift 2 ;;
    -h|--help)   sed -n '2,17p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$role" ] || die "--role is required"
[ -n "$action" ] || die "--action is required"
case "$outcome" in ok|error|stopped|skipped) ;; *) die "--outcome must be ok, error, stopped or skipped" ;; esac
if [ -n "$cost" ] && ! [[ "$cost" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then die "--cost-usd must be a number"; fi

log="${GRID_RUN_LOG:-$HOME/.the-grid-private/runs.jsonl}"
mkdir -p "$(dirname "$log")"
chmod 700 "$(dirname "$log")" 2>/dev/null || true   # only tighten; a shared dir we do not own is left alone

# Build the JSON in python so quotes, newlines and unicode in free text can never break the line.
line="$(ROLE="$role" ACTION="$action" OUTCOME="$outcome" TARGET="$target" OPERATOR="$operator" COST="$cost" NOTE="$note" HOST="$(hostname -s)" \
  python3 - <<'PY'
import json, os, time
e = os.environ
rec = {
    "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "host": e["HOST"], "role": e["ROLE"], "operator": e["OPERATOR"],
    "action": e["ACTION"], "target": e["TARGET"], "outcome": e["OUTCOME"],
    "cost_usd": float(e["COST"]) if e["COST"] else None,
    "note": e["NOTE"][:500],
}
print(json.dumps(rec, ensure_ascii=False))
PY
)"

# One short line, appended in a single write; the file is created 0600.
( umask 077; printf '%s\n' "$line" >> "$log" )
