#!/usr/bin/env bash
# repo-metadata.sh — compare (and optionally set) the public repo's GitHub description,
# homepage and topics against the constants below.
#
#   bash scripts/repo-metadata.sh [--check|--apply]      (default --check)
#
# --check  read-only: one `gh repo view`, prints a diff, exit 0 when everything matches,
#          exit 1 on drift.
# --apply  prints the same diff, then runs `gh repo edit` once for description+homepage
#          (only when either differs) and once per missing (--add-topic) or extra
#          (--remove-topic) topic. A second run finds no drift and calls nothing.
#          This changes the live repo: the operator reads a --check diff first.
#
# Repo = ${GRID_REPO} (owner/name) else parsed from `git remote get-url origin`:
#   git@<host-alias>:owner/repo(.git)   ssh://git@host/owner/repo(.git)   https://host/owner/repo(.git)
#
# Why python3 -I and not jq: jq is not a dependency of this repo; -I ignores the
# environment and the current directory, so no stray module is imported.
#
# Exit codes: 0 match (or --apply done), 1 drift (--check), 2 usage or environment error
# (gh missing/unauthenticated, no repo, bad JSON, gh failure).
set -euo pipefail
export LC_ALL=C

# ---- desired state (edit here, nowhere else) ----
WANT_DESCRIPTION='Dotfiles for your AI assistant: curated skills and agent teams, wired identically onto every machine. Claude Code today, more AI tools next.'
WANT_HOMEPAGE='https://oneafrikan.github.io/the-grid/'
WANT_TOPICS='claude-code
claude-skills
claude-code-skills
agent-skills
ai-agents
dotfiles
subagents
skills-manager
developer-tools'

die() { echo "repo-metadata: $*" >&2; exit 2; }

mode=check
case "${1:-}" in
  ""|--check) mode=check ;;
  --apply) mode=apply ;;
  *) echo "usage: repo-metadata.sh [--check|--apply]" >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { echo "usage: repo-metadata.sh [--check|--apply]" >&2; exit 2; }

# ---- tools ----
command -v gh >/dev/null 2>&1 || die "gh is not installed (https://cli.github.com)"
command -v python3 >/dev/null 2>&1 || die "python3 is not installed"
# Checked up front so a logged-out gh gives one clear message, not a confusing view error.
gh auth status >/dev/null 2>&1 || die "gh is not authenticated (run: gh auth login)"

# ---- which repo ----
repo="${GRID_REPO:-}"
if [ -z "$repo" ]; then
  url="$(git remote get-url origin 2>/dev/null)" || die "no GRID_REPO and no git remote 'origin' here"
  case "$url" in
    *://*) path="${url#*://}"; path="${path#*/}" ;;   # scheme://[user@]host[:port]/owner/repo
    *:*) path="${url#*:}" ;;                          # scp-like [user@]host-alias:owner/repo
    *) die "cannot parse remote url: $url" ;;
  esac
  path="${path%/}"
  repo="${path%.git}"
fi
case "$repo" in
  */*/*|/*|*/|*[[:space:]]*|"") die "repo is not owner/name: $repo" ;;
  */*) ;;
  *) die "repo is not owner/name: $repo" ;;
esac

# ---- current state ----
json="$(gh repo view "$repo" --json description,homepageUrl,repositoryTopics)" \
  || die "gh repo view $repo failed"

# Emits tab-separated lines: "D<TAB>description", "H<TAB>homepage", "T<TAB>topic" (one per topic).
# repositoryTopics is null for a repo with no topics, else a list of {"name"} or {"topic":{"name"}}.
parsed="$(printf '%s' "$json" | python3 -I -c '
import json, sys
try:
    d = json.load(sys.stdin)
except ValueError as e:
    sys.exit("invalid JSON from gh: %s" % e)
one = lambda s: " ".join((s or "").split("\n"))
print("D\t" + one(d.get("description")))
print("H\t" + one(d.get("homepageUrl")))
for t in d.get("repositoryTopics") or []:
    name = t.get("name") or (t.get("topic") or {}).get("name") if isinstance(t, dict) else None
    if not name:
        sys.exit("unrecognised repositoryTopics entry: %r" % (t,))
    print("T\t" + name)
')" || die "could not parse gh output"

have_desc=""; have_home=""; have_topics=""
while IFS=$'\t' read -r kind val; do
  case "$kind" in
    D) have_desc="$val" ;;
    H) have_home="$val" ;;
    T) have_topics="${have_topics:+$have_topics
}$val" ;;
  esac
done <<EOF
$parsed
EOF

# ---- diff ----
drift=0; meta_drift=0; missing=""; extra=""
if [ "$have_desc" != "$WANT_DESCRIPTION" ]; then
  drift=1; meta_drift=1
  printf 'description differs:\n- %s\n+ %s\n' "$have_desc" "$WANT_DESCRIPTION"
fi
if [ "$have_home" != "$WANT_HOMEPAGE" ]; then
  drift=1; meta_drift=1
  printf 'homepage differs:\n- %s\n+ %s\n' "$have_home" "$WANT_HOMEPAGE"
fi
while IFS= read -r t; do
  [ -n "$t" ] || continue
  if ! printf '%s\n' "$have_topics" | grep -Fxq -- "$t"; then
    drift=1; missing="${missing:+$missing
}$t"
    printf 'topic missing: + %s\n' "$t"
  fi
done <<EOF
$WANT_TOPICS
EOF
while IFS= read -r t; do
  [ -n "$t" ] || continue
  if ! printf '%s\n' "$WANT_TOPICS" | grep -Fxq -- "$t"; then
    drift=1; extra="${extra:+$extra
}$t"
    printf 'topic extra: - %s\n' "$t"
  fi
done <<EOF
$have_topics
EOF

if [ "$drift" = 0 ]; then
  echo "repo-metadata: $repo matches"
  exit 0
fi

if [ "$mode" = check ]; then
  echo "repo-metadata: $repo has drifted (run with --apply to fix)" >&2
  exit 1
fi

# ---- apply ----
if [ "$meta_drift" = 1 ]; then
  gh repo edit "$repo" --description "$WANT_DESCRIPTION" --homepage "$WANT_HOMEPAGE"
fi
while IFS= read -r t; do
  [ -n "$t" ] || continue
  gh repo edit "$repo" --add-topic "$t"
done <<EOF
$missing
EOF
while IFS= read -r t; do
  [ -n "$t" ] || continue
  gh repo edit "$repo" --remove-topic "$t"
done <<EOF
$extra
EOF
echo "repo-metadata: applied to $repo"
