#!/usr/bin/env bash
# the-grid — deploy_openclaw.sh
#
# Deploys a compose.py `write_openclaw()` rendered role (9-file identity set) into a
# live OpenClaw workspace on this host (scout), and registers it with the running
# `openclaw-gateway` container.
#
# This is a direct port of Guide's generate.sh regen logic + ADD-AN-AGENT.md's
# register/bind/allowlist runbook (~/Guide/guide-core/agent-factory/), adapted for:
#   - scout's Telegram-only messaging surface (no Slack)
#   - the-grid's role source (compose.py output) instead of Guide's roles/*.env
#   - a single shared workspace dir per role, not channel/specialist/personal variants
#
# Session B3 scope: this script proves the mechanism against a THROWAWAY TEST AGENT.
# Do not point it at a real orchestrator (ceo-orchestrator, tech-lead, finance-manager,
# growth-hacker, product-manager) until Session C (security review) has run and Session
# B4 explicitly authorizes it — see agent-factory/docs/openclaw-paperclip-targets-plan.md.
#
# Usage:
#   deploy_openclaw.sh install   <role> <source-dir>          # copy 9-file set into workspace, idempotent
#   deploy_openclaw.sh register  <role>                       # docker exec ... agents add (live)
#   deploy_openclaw.sh bind      <role> <telegram-account-id>  [--execute]   # dry-run by default
#   deploy_openclaw.sh allowlist-check                        # read-only: report the Telegram allowlist key path
#   deploy_openclaw.sh verify    <role>                       # docker exec ... agents list --json, grep for role
#   deploy_openclaw.sh cleanup   <role>                       # docker exec ... agents delete --force
#   deploy_openclaw.sh cron-snapshot                          # snapshot cron job count before any restart
#   deploy_openclaw.sh cron-verify <count-before>             # re-query cron count, compare
#
# No subcommand performs a `docker compose restart` — that is a separate, explicit
# decision (see plan Session B3 step 5) and is deliberately NOT wired as a default
# action of this script. If a restart turns out to be necessary, run it by hand
# following jarvis-core/CLAUDE.md's safety dance; cron-snapshot/cron-verify above
# are provided to support that by hand.

set -euo pipefail

CONTAINER="openclaw-gateway"
OPENCLAW_ROOT="$HOME/.openclaw"
CRON_DB="$OPENCLAW_ROOT/state/openclaw.sqlite"

# --- shared helpers -----------------------------------------------------------

workspace_dir() { echo "$OPENCLAW_ROOT/workspace-$1"; }
agent_dir()     { echo "$OPENCLAW_ROOT/agents/$1/agent"; }

# Apply B2's file-permission scheme. Safe to re-run (chmod is idempotent).
#   IDENTITY/SOUL            -> 440  (locked, regenerated from source every run)
#   AGENTS/USER/BOOT/BOOTSTRAP -> 644 (engineer-editable)
#   TOOLS/HEARTBEAT/MEMORY    -> 664 (agent-writable, preserved on regen)
#   EXPERTISE                -> 640 (gareth-maintained, preserved on regen)
apply_permissions() {
  local ws="$1"
  for f in IDENTITY SOUL; do
    [[ -f "$ws/$f.md" ]] && chmod 440 "$ws/$f.md"
  done
  for f in AGENTS USER BOOT BOOTSTRAP; do
    [[ -f "$ws/$f.md" ]] && chmod 644 "$ws/$f.md"
  done
  for f in TOOLS HEARTBEAT MEMORY; do
    [[ -f "$ws/$f.md" ]] && chmod 664 "$ws/$f.md"
  done
  [[ -f "$ws/EXPERTISE.md" ]] && chmod 640 "$ws/EXPERTISE.md"
}

# --- install -------------------------------------------------------------------
#
# Copies the rendered 9-file set from <source-dir> into ~/.openclaw/workspace-<role>.
# Always overwrites IDENTITY/SOUL/AGENTS/USER.md (source of truth, regenerated every
# run). Skips MEMORY/TOOLS/HEARTBEAT/EXPERTISE.md if they already exist AND are
# non-empty (agent-writable / hand-authored — must not be clobbered on regen). This
# is Guide's exact generate.sh condition (`-s "$output"` = file exists and is
# non-empty), applied to all four preserve-on-regen files per the plan's B2 table.
cmd_install() {
  local role="$1" src="$2"
  local ws; ws="$(workspace_dir "$role")"

  [[ -d "$src" ]] || { echo "install: source dir not found: $src" >&2; exit 1; }

  mkdir -p "$ws"
  echo "install: workspace -> $ws"

  local always_overwrite=(IDENTITY SOUL AGENTS USER)
  local preserve_if_present=(MEMORY TOOLS HEARTBEAT EXPERTISE)

  for f in "${always_overwrite[@]}"; do
    if [[ -f "$src/$f.md" ]]; then
      # Unlock before overwrite — IDENTITY/SOUL are 440 after a prior install.
      [[ -f "$ws/$f.md" ]] && chmod u+w "$ws/$f.md"
      cp "$src/$f.md" "$ws/$f.md"
      echo "  wrote  $f.md (source of truth, always overwritten)"
    fi
  done

  for f in "${preserve_if_present[@]}"; do
    local out="$ws/$f.md"
    if [[ -f "$out" && -s "$out" ]]; then
      echo "  skip   $f.md (already has content — preserved)"
      continue
    fi
    if [[ -f "$src/$f.md" ]]; then
      cp "$src/$f.md" "$out"
      echo "  wrote  $f.md (first write / was empty)"
    fi
  done

  # BOOT.md / BOOTSTRAP.md are engineer-editable operating files, same overwrite
  # rule as AGENTS/USER — copy if the source provides them.
  for f in BOOT BOOTSTRAP; do
    if [[ -f "$src/$f.md" ]]; then
      [[ -f "$ws/$f.md" ]] && chmod u+w "$ws/$f.md"
      cp "$src/$f.md" "$ws/$f.md"
      echo "  wrote  $f.md (source of truth, always overwritten)"
    fi
  done

  apply_permissions "$ws"
  echo "install: permissions applied"
}

# --- agent dir -------------------------------------------------------------------

cmd_agentdir() {
  local role="$1"
  local ad; ad="$(agent_dir "$role")"
  mkdir -p "$ad"
  echo "agentdir: $ad (created if missing)"
}

# --- register --------------------------------------------------------------------

cmd_register() {
  local role="$1"
  local ws; ws="$(workspace_dir "$role")"
  local ad; ad="$(agent_dir "$role")"

  echo "register: docker exec $CONTAINER openclaw agents add $role --workspace $ws --agent-dir $ad --non-interactive"
  docker exec "$CONTAINER" openclaw agents add "$role" \
    --workspace "$ws" \
    --agent-dir "$ad" \
    --non-interactive \
    --json
}

# --- bind (Telegram) ---------------------------------------------------------------
#
# Dry-run by default: prints the exact command, does not execute it. There is no
# safe disposable Telegram surface to test against yet, so binding for real is out
# of scope for this session (see plan doc, step 4). Pass --execute to actually run
# it once a real dedicated bot/account exists for the role being deployed.
cmd_bind() {
  local role="$1" account="$2" execute="${3:-}"
  local bind_cmd=(docker exec "$CONTAINER" openclaw agents bind --agent "$role" --bind "telegram:$account" --json)

  if [[ "$execute" == "--execute" ]]; then
    echo "bind: EXECUTING: ${bind_cmd[*]}"
    "${bind_cmd[@]}"
  else
    echo "bind: DRY RUN (pass --execute to actually run):"
    echo "  ${bind_cmd[*]}"
  fi
}

# --- allowlist check (read-only) ---------------------------------------------------
#
# Reports the live equivalent of Guide's `channels.slack.channels` allowlist gate.
# Does NOT modify openclaw.json. On scout, the gate is:
#   channels.telegram.accounts.<accountId>.groupPolicy == "allowlist"
#   channels.telegram.groups.<groupId>.allowFrom == [<telegram-user-id>, ...]
# A group/DM not listed here is silently dropped by the gateway (same failure mode
# Guide documents for Slack) — this must be added by hand before a real bind, and is
# explicitly out of scope to touch in this session.
cmd_allowlist_check() {
  python3 - "$OPENCLAW_ROOT/openclaw.json" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
tg = cfg.get("channels", {}).get("telegram", {})
print("Read-only finding — channels.telegram allowlist shape on this host:")
print("  key path: channels.telegram.accounts.<accountId>.groupPolicy  (gate: must be \"allowlist\")")
print("  key path: channels.telegram.groups.<groupId>.allowFrom        (array of telegram user ids)")
print()
print("Current accounts:", list(tg.get("accounts", {}).keys()))
for acct, val in tg.get("accounts", {}).items():
    print(f"  accounts.{acct}.groupPolicy = {val.get('groupPolicy')!r}")
print("Current groups:", list(tg.get("groups", {}).keys()))
print()
print("No changes made. Adding a new role's group/account here is a separate,")
print("explicit step before any real bind (out of scope for this test run).")
PY
}

# --- verify ---------------------------------------------------------------------

cmd_verify() {
  local role="$1"
  echo "verify: docker exec $CONTAINER openclaw agents list --json | grep for '$role'"
  docker exec "$CONTAINER" openclaw agents list --json | python3 -c "
import json, sys
role = sys.argv[1]
data = json.load(sys.stdin)
match = [a for a in data if a.get('id') == role]
if match:
    print('FOUND:', json.dumps(match[0], indent=2))
    sys.exit(0)
else:
    print('NOT FOUND:', role)
    sys.exit(1)
" "$role"
}

# --- cleanup ---------------------------------------------------------------------

cmd_cleanup() {
  local role="$1"
  echo "cleanup: docker exec $CONTAINER openclaw agents delete $role --force"
  docker exec "$CONTAINER" openclaw agents delete "$role" --force --json
  echo "cleanup: removing local workspace/agent dirs (agents delete prunes container-side state; these are host paths)"
  rm -rf "$(workspace_dir "$role")" "$OPENCLAW_ROOT/agents/$role"
}

# --- cron snapshot / verify (support for a hand-run restart, not automated here) ---

cmd_cron_snapshot() {
  [[ -f "$CRON_DB" ]] || { echo "cron-snapshot: $CRON_DB not found" >&2; exit 1; }
  sqlite3 "$CRON_DB" "SELECT COUNT(*) FROM cron_jobs;"
}

cmd_cron_verify() {
  local before="$1"
  local after
  after="$(sqlite3 "$CRON_DB" "SELECT COUNT(*) FROM cron_jobs;")"
  if [[ "$before" == "$after" ]]; then
    echo "cron-verify: OK ($after jobs, unchanged)"
  else
    echo "cron-verify: MISMATCH — before=$before after=$after" >&2
    exit 1
  fi
}

# --- dispatch ---------------------------------------------------------------------

cmd="${1:-}"; shift || true
case "$cmd" in
  install)          cmd_install "$@" ;;
  agentdir)          cmd_agentdir "$@" ;;
  register)          cmd_register "$@" ;;
  bind)              cmd_bind "$@" ;;
  allowlist-check)   cmd_allowlist_check "$@" ;;
  verify)            cmd_verify "$@" ;;
  cleanup)           cmd_cleanup "$@" ;;
  cron-snapshot)     cmd_cron_snapshot "$@" ;;
  cron-verify)       cmd_cron_verify "$@" ;;
  *)
    echo "Usage: $0 {install|agentdir|register|bind|allowlist-check|verify|cleanup|cron-snapshot|cron-verify} ..." >&2
    exit 1
    ;;
esac
