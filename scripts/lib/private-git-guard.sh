#!/usr/bin/env bash
# private-git-guard.sh — safety checks shared by the two unattended jobs that commit
# to the private repo: scripts/usage/weekly.sh and `instincts.sh sync` (run_sync in
# scripts/instincts/analyse.py). One bash helper, called by both, so the two jobs
# cannot drift apart on what "safe to touch the private repo" means.
#
# Usage:
#   private-git-guard.sh precheck <dir>
#       Exit 0: nothing in progress, safe to run the git phase.
#       Exit 1: the repo is busy; ONE reason token on stdout:
#         rebase-in-progress | merge-in-progress | cherry-pick-in-progress |
#         detached-head | unmerged-entries | no-upstream
#       The jobs skip their whole git phase on a busy repo: it is the operator's
#       work in progress (or a state a push cannot succeed from), never theirs to fix.
#
#   private-git-guard.sh outside-clean <dir> <pathspec>
#       Exit 0: no tracked change (staged or not) outside <pathspec>.
#       Exit 1: there is one. The jobs then skip only the pull (a rebase would
#       refuse, and --autostash would re-apply the operator's edit into conflict
#       markers) and still commit their own path.
#
#   private-git-guard.sh push-ok <dir> <pathspec>
#       Exit 0: safe to `git push`.
#       Exit 3: the push remote is not confirmed (no marker file, or it does not
#               match). The jobs skip the push with a warning and still exit 0.
#       Exit 4: an unpushed commit touches something other than <pathspec> (or is a
#               merge). The jobs skip the push and report failure.
#       A one-line reason is printed on stdout for exits 3 and 4.
#
#   private-git-guard.sh push-args <dir>
#       Prints "<remote> HEAD:refs/heads/<branch>": the remote and branch that push-ok
#       validated (branch.<b>.remote and branch.<b>.merge). The jobs push EXACTLY that,
#       with `git -c push.default=nothing push <remote> <refspec>`, so no push.default,
#       branch.<b>.pushRemote or remote.pushDefault setting can send anything elsewhere.
#       Exit 3 (reason on stdout) when it cannot be resolved.
#
# Remote marker: <dir>/.grid-private-remote holds, on its first line, the push URL of
# the upstream remote, e.g.
#   git -C <dir> remote get-url --push origin > <dir>/.grid-private-remote
# The operator creates it once per machine after checking the repo is private. The
# helper cannot know that itself; the marker pins "the remote I confirmed" so a
# changed or mis-set remote can never receive the job's commits.
#
# <pathspec> is relative to the repo root; a commit is "own" when every path it
# touches equals <pathspec> or sits under <pathspec>/.

set -u

# A git hook (the commit gate) exports these; they would redirect every call below.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

MARKER_NAME=".grid-private-remote"

die_usage() {
  echo "usage: private-git-guard.sh precheck <dir> | outside-clean <dir> <pathspec> | push-ok <dir> <pathspec> | push-args <dir>" >&2
  exit 2
}

# host_of <url> — the host only: scheme, credentials, port and path stripped, so a
# log line can never carry a token embedded in a remote URL.
host_of() {
  printf '%s' "$1" | sed -E 's#^[A-Za-z+.-]+://##; s#^[^@/]*@##; s#[:/].*$##'
}

# gitpath <dir> <name> — absolute path of a file/dir inside the git dir (worktree
# and submodule layouts included), via rev-parse --git-path.
gitpath() {
  local p
  p="$(git -C "$1" rev-parse --git-path "$2" 2>/dev/null)" || return 1
  case "$p" in /*) ;; *) p="$1/$p" ;; esac
  printf '%s' "$p"
}

cmd_precheck() {
  local dir="$1" p
  p="$(gitpath "$dir" rebase-merge)" && [ -e "$p" ] && { echo rebase-in-progress; return 1; }
  p="$(gitpath "$dir" rebase-apply)" && [ -e "$p" ] && { echo rebase-in-progress; return 1; }
  p="$(gitpath "$dir" MERGE_HEAD)" && [ -e "$p" ] && { echo merge-in-progress; return 1; }
  p="$(gitpath "$dir" CHERRY_PICK_HEAD)" && [ -e "$p" ] && { echo cherry-pick-in-progress; return 1; }
  git -C "$dir" symbolic-ref -q HEAD >/dev/null 2>&1 || { echo detached-head; return 1; }
  [ -z "$(git -C "$dir" ls-files -u 2>/dev/null | head -n 1)" ] || { echo unmerged-entries; return 1; }
  git -C "$dir" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1 || { echo no-upstream; return 1; }
  return 0
}

cmd_outside_clean() {
  local dir="$1" spec="$2" changed
  # -uno: untracked files never block a pull. The exclude pathspec drops the job's own path.
  changed="$(git -C "$dir" status --porcelain --untracked-files=no -- . ":(exclude)$spec" 2>/dev/null)" || return 1
  [ -z "$changed" ]
}

cmd_push_args() {
  local dir="$1" branch remote merge
  branch="$(git -C "$dir" symbolic-ref -q --short HEAD)" || { echo "detached-head"; return 3; }
  remote="$(git -C "$dir" config "branch.$branch.remote")" || { echo "no-upstream-remote"; return 3; }
  merge="$(git -C "$dir" config "branch.$branch.merge")" || { echo "no-upstream-branch"; return 3; }
  case "$merge" in
    refs/heads/?*) ;;
    *) echo "unsupported-upstream-ref"; return 3 ;;
  esac
  printf '%s HEAD:%s\n' "$remote" "$merge"
}

cmd_push_ok() {
  local dir="$1" spec="$2" branch remote url marker want path
  branch="$(git -C "$dir" symbolic-ref -q --short HEAD)" || { echo "detached-head"; return 3; }
  remote="$(git -C "$dir" config "branch.$branch.remote")" || { echo "no-upstream-remote"; return 3; }
  url="$(git -C "$dir" remote get-url --push "$remote" 2>/dev/null)" || { echo "no-push-url"; return 3; }

  # Remote check first: nothing below matters if the destination is not the confirmed one.
  marker="$dir/$MARKER_NAME"
  if [ ! -f "$marker" ]; then
    echo "no marker file $MARKER_NAME (push remote host: $(host_of "$url"))"
    return 3
  fi
  want="$(head -n 1 "$marker" | tr -d '\r')"
  if [ "$want" != "$url" ]; then
    echo "push remote does not match $MARKER_NAME (push remote host: $(host_of "$url"), marker host: $(host_of "$want"))"
    return 3
  fi

  # Scope check: every unpushed commit may touch only the job's own path.
  if [ -n "$(git -C "$dir" rev-list --merges '@{u}..HEAD' 2>/dev/null | head -n 1)" ]; then
    echo "foreign-commits: unpushed merge commit"
    return 4
  fi
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    case "$path" in
      "$spec"|"$spec"/*) ;;
      *) echo "foreign-commits: unpushed commit touches $path"; return 4 ;;
    esac
  # core.quotePath=false: otherwise git C-quotes a non-ASCII name ("h\303\266st") and the
  # job's own commit would be taken for a foreign one.
  done < <(git -C "$dir" -c core.quotePath=false log --no-merges --no-renames --name-only --format= '@{u}..HEAD' 2>/dev/null)
  return 0
}

[ $# -ge 2 ] || die_usage
sub="$1"; dir="$2"
case "$sub" in
  precheck)       [ $# -eq 2 ] || die_usage; cmd_precheck "$dir" ;;
  outside-clean)  [ $# -eq 3 ] || die_usage; cmd_outside_clean "$dir" "$3" ;;
  push-ok)        [ $# -eq 3 ] || die_usage; cmd_push_ok "$dir" "$3" ;;
  push-args)      [ $# -eq 2 ] || die_usage; cmd_push_args "$dir" ;;
  *)              die_usage ;;
esac
