#!/usr/bin/env bash
# bootstrap.sh — one-command machine setup for the-grid.
#
# Runs from inside an existing clone of the-grid and brings the machine fully
# online: sync submodules → wire skills → (optionally) compose + wire the
# agent-factory team. Mirrors the manual sequence in BOOTSTRAP.md so the two
# never drift — if you change the boot steps, change them here.
#
# The initial `git clone` can't be done by a script that lives *inside* the
# repo, so the true new-machine one-liner is:
#
#   git clone <repo-url> ~/.the-grid && bash ~/.the-grid/scripts/bootstrap.sh
#
# Usage:
#   bash scripts/bootstrap.sh                 # submodules + wire skills
#   bash scripts/bootstrap.sh --with-agents   # also compose + wire the grid team agents
#   bash scripts/bootstrap.sh --reshallow     # OPT-IN, runs ONLY this (no sync/wire): convert
#                                             # existing full-history submodule checkouts to
#                                             # depth 1 at their pin to reclaim disk. Skips (and
#                                             # says why) any that is already shallow, dirty, or
#                                             # not at the pin. Backs up and restores on failure.
#
# Env (same contract as wire.sh):
#   GRID_DIR    — root of the-grid repo   (default: parent of scripts/)
#   SKILLS_DIR  — Claude skills directory (default: ~/.claude/skills)
#   AGENTS_DIR  — Claude subagents directory (default: ~/.claude/agents)
set -euo pipefail

GRID_DIR="${GRID_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
WITH_AGENTS=0
RESHALLOW=0

for arg in "$@"; do
  case "$arg" in
    --with-agents) WITH_AGENTS=1 ;;
    --reshallow) RESHALLOW=1 ;;
    -h|--help)
      sed -n '2,/^set -euo/{/^set -euo/!p;}' "$0"  # print the header comment as help
      exit 0 ;;
    *) echo "bootstrap.sh: unknown argument: $arg" >&2; exit 2 ;;
  esac
done

cd "$GRID_DIR"

# --reshallow: opt-in, never part of a normal run. Re-clone each already-initialised top-level
# submodule at depth 1 (its pin only), reclaiming the history. Per submodule it SKIPS, printing
# why, when it is not initialised, already shallow, dirty, or its HEAD is not the pin the
# superproject records (a moved HEAD means local or unpushed work). Otherwise the module git
# dir and the working tree are MOVED aside (not deleted), a fresh depth-1 clone is made, and the
# backups are deleted only once the new clone is verified (shallow, HEAD == pin). Any failure or
# INT/TERM restores both backups, so a dropped network loses nothing. A second run is a no-op.
# ponytail: the module git dir is taken from the submodule itself (rev-parse --absolute-git-dir)
# rather than rebuilt from the .gitmodules name; same dir, also right inside a linked worktree.
RS_GITDIR="" RS_BAK="" RS_WT="" RS_WTBAK=""
rs_rollback() {
  # Remove whatever the failed/interrupted clone left, then put the backups back.
  [[ -n "$RS_BAK" && -d "$RS_BAK" ]] || return 0
  # Only clear the working tree when its backup exists (else it is still the real one).
  if [[ -d "$RS_WTBAK" ]]; then rm -rf "$RS_WT"; mv "$RS_WTBAK" "$RS_WT"; fi
  rm -rf "$RS_GITDIR"
  mv "$RS_BAK" "$RS_GITDIR"
  RS_BAK=""
}
reshallow_all() {
  local paths=() p pin head gitdir kb_before kb_after err
  local total_kb=0 n_ok=0 n_skip=0 n_fail=0
  # Collect first: git inside the loop must not share a stdin with the read.
  while read -r _ p; do paths+=("$p"); done < <(git config -f .gitmodules --get-regexp '^submodule\..*\.path$')
  for p in ${paths[@]+"${paths[@]}"}; do
    case "$p" in ''|/*|*..*) echo "reshallow: $p: skipped (unsafe path)"; n_skip=$((n_skip+1)); continue ;; esac
    if [[ ! -f "$p/.git" ]]; then
      echo "reshallow: $p: skipped ($([[ -d "$p/.git" ]] && echo 'embedded .git dir, not an absorbed submodule' || echo 'not initialised'))"
      n_skip=$((n_skip+1)); continue
    fi
    pin="$(git ls-files -s -- "$p" | awk '$1 == "160000" {print $2}')"
    head="$(git -C "$p" rev-parse HEAD 2>/dev/null || true)"
    gitdir="$(git -C "$p" rev-parse --absolute-git-dir 2>/dev/null || true)"
    if [[ -z "$pin" || -z "$gitdir" ]]; then
      echo "reshallow: $p: skipped (cannot read the recorded pin or git dir)"; n_skip=$((n_skip+1)); continue
    elif [[ "$(git -C "$p" rev-parse --is-shallow-repository)" == "true" ]]; then
      echo "reshallow: $p: skipped (already shallow)"; n_skip=$((n_skip+1)); continue
    elif [[ -n "$(git -C "$p" status --porcelain)" ]]; then
      echo "reshallow: $p: skipped (dirty working tree)"; n_skip=$((n_skip+1)); continue
    elif [[ "$head" != "$pin" ]]; then
      echo "reshallow: $p: skipped (HEAD ${head:0:12} is not the recorded pin ${pin:0:12}; local or unpushed work?)"
      n_skip=$((n_skip+1)); continue
    elif [[ "$gitdir" != */modules/* ]]; then
      echo "reshallow: $p: skipped (git dir $gitdir is not under modules/)"; n_skip=$((n_skip+1)); continue
    elif [[ -e "$gitdir.reshallow-bak" || -e "$p.reshallow-bak" ]]; then
      echo "reshallow: $p: skipped (leftover backup from an interrupted run: $gitdir.reshallow-bak or $p.reshallow-bak)"
      n_skip=$((n_skip+1)); continue
    fi
    kb_before="$(du -sk "$gitdir" | cut -f1)"
    RS_GITDIR="$gitdir"; RS_BAK="$gitdir.reshallow-bak"; RS_WT="$GRID_DIR/$p"; RS_WTBAK="$GRID_DIR/$p.reshallow-bak"
    trap 'rs_rollback; exit 130' INT TERM HUP
    if err="$(mv "$gitdir" "$RS_BAK" && mv "$p" "$RS_WTBAK" && mkdir "$p" \
              && git submodule update --init --depth 1 -- "$p" </dev/null 2>&1)" \
       && [[ "$(git -C "$p" rev-parse --is-shallow-repository)" == "true" ]] \
       && [[ "$(git -C "$p" rev-parse HEAD)" == "$pin" ]]; then
      rm -rf "$RS_BAK" "$RS_WTBAK"; RS_BAK=""
      kb_after="$(du -sk "$gitdir" | cut -f1)"
      total_kb=$((total_kb + kb_before - kb_after)); n_ok=$((n_ok+1))
      echo "reshallow: $p: shallow at ${pin:0:12} ($((kb_before/1024)) MiB -> $((kb_after/1024)) MiB)"
    else
      rs_rollback; n_fail=$((n_fail+1))
      echo "reshallow: $p: FAILED, original restored. ${err##*$'\n'}" >&2
    fi
    trap - INT TERM HUP
  done
  echo "reshallow: $n_ok converted, $n_skip skipped, $n_fail failed; reclaimed $((total_kb/1024)) MiB"
  [[ "$n_fail" -eq 0 ]]
}

if [[ "$RESHALLOW" == "1" ]]; then
  reshallow_all
  exit $?
fi

# 0. Warn (never fail, never change config) when the global git email is empty
#    or not a GitHub noreply address: GitHub rejects pushes that expose a
#    private address. Only the users.noreply.github.com suffix is tested.
git_email="$(git config --global user.email 2>/dev/null || true)"
if [[ "$git_email" != *@users.noreply.github.com ]]; then
  echo "WARN: global git user.email is ${git_email:-unset}, not a GitHub noreply address." >&2
  echo "WARN: commits would publish it, and GitHub blocks pushes that expose a private address. Run:" >&2
  echo "WARN:   git config --global user.email \"<id>+<login>@users.noreply.github.com\"" >&2
fi

# 1. Sync every skill submodule to the pointer this commit records.
echo "==> [1/4] Syncing submodules (git submodule update --init --recursive)"
# Submodules not cloned yet (`git submodule status` prefix "-") are fetched at depth 1: just the
# pinned commit, no history. Already-initialised ones get the plain update below, never --depth,
# which would also shallow-fetch into an existing full checkout and truncate a maintainer's
# history (use --reshallow to do that on purpose). .gitmodules also says `shallow = true`, but
# git's fallback fetch of a pin that is behind the upstream tip ignores that and pulls full
# history, so the explicit --depth is what makes those (e.g. openclaw) shallow.
fresh=()
while read -r sha p _; do
  case "$sha" in -*) fresh+=("$p") ;; esac
done < <(git submodule status)
if [[ ${#fresh[@]} -gt 0 ]]; then
  git submodule update --init --depth 1 --recursive -- "${fresh[@]}"
fi
git submodule update --init --recursive

# Activate the in-repo git hooks (pre-commit runs bats). Idempotent; only
# affects commits made in this repo, so it's harmless on consumer machines.
git config core.hooksPath .githooks

# 2. Seed the wiring manifest (personal curation, gitignored — see #24).
#    Skip a file that already exists; without this, wire.sh falls back to
#    wiring every repo (harmless but noisy) instead of the curated baseline.
echo "==> [2/4] Seeding wiring manifest from examples (baseline-submodules.txt, machines/$(hostname -s).txt)"
[[ -f "$GRID_DIR/baseline-submodules.txt" ]] || cp "$GRID_DIR/baseline-submodules.example.txt" "$GRID_DIR/baseline-submodules.txt"
[[ -f "$GRID_DIR/machines/$(hostname -s).txt" ]] || cp "$GRID_DIR/machines/example.txt" "$GRID_DIR/machines/$(hostname -s).txt"

# 3. Wire skills (and any already-composed agents) into Claude.
echo "==> [3/4] Wiring skills (scripts/wire.sh)"
bash "$GRID_DIR/scripts/wire.sh"

# 4. Optionally build the composed agent team, then re-wire so the freshly
#    compiled orchestrator skills + specialist subagents go live.
if [[ "$WITH_AGENTS" == "1" ]]; then
  echo "==> [4/4] Composing agent-factory teams (core, grid, finance-desk) + re-wiring"
  cd "$GRID_DIR/agent-factory"
  # Create the venv on first run; reuse it afterwards (idempotent).
  if [[ ! -x .venv/bin/python ]]; then
    python3 -m venv .venv
    .venv/bin/pip install -q -r requirements.txt
  fi
  .venv/bin/python compose.py examples/core.yaml --target claude-code
  .venv/bin/python compose.py examples/grid.yaml --target claude-code
  .venv/bin/python compose.py examples/finance-desk.yaml --target claude-code
  .venv/bin/python compose.py examples/learning-desk.yaml --target claude-code
  cd "$GRID_DIR"
  bash "$GRID_DIR/scripts/wire.sh"
else
  echo "==> [4/4] Skipping agent-factory (pass --with-agents to compose + wire the team)"
fi

# Remind (print only, never prompt: this must stay safe unattended) when agents were
# composed without an operator identity. compose.py bakes user.yaml into every agent, so a
# missing file ships agents saying "No operator set yet." until it is added and re-composed.
# Re-running this script is idempotent (venv reused, compose.py rewrites its output, wire.sh
# rebuilds links), so it is the simplest way to recompose.
user_cfg="${GRID_USER_CONFIG:-$GRID_DIR/agent-factory/user.yaml}"
if [[ "$WITH_AGENTS" == "1" && ! -f "$user_cfg" ]]; then
  # Absolute paths so the commands work from any directory, not only inside the clone.
  echo "==> NOTE: no operator identity yet ($user_cfg). Agents will say \"No operator set yet.\""
  echo "==>   cp \"$GRID_DIR/agent-factory/user.yaml.example\" \"$user_cfg\"   # then fill in your name and contact"
  echo "==>   bash \"$GRID_DIR/scripts/bootstrap.sh\" --with-agents   # re-run so the agents pick it up"
fi

echo "==> Bootstrap complete. Open a fresh Claude session to pick up new skills/agents."
