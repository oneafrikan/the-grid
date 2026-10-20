#!/usr/bin/env bash
# Shared builders for the scripts/grid tests (manifest-lock-install). Sourced by
# each .bats file via `load helpers/grid_fixture` AFTER `load helpers/setup`.
#
# Everything is built inside the test from throwaway directories: no test
# touches the network, the real ~/.grid, or the real ~/.claude.
#
# Portability (macOS runs bash 3.2 and BSD tools; Ubuntu and Arch run GNU): no
# mapfile/readarray, no `declare -A`, no ${x,,}; no `sed -i`, `stat -c`/`-f`,
# `date -d`/`-v`, `readlink -f`, `shasum`/`sha256sum`. Anything that needs file
# metadata or a digest goes through python3 (tree_digest, file_id below).

# --- environment isolation ---------------------------------------------------
# grid_env_isolate <root>: point every directory grid (or the wire.sh it runs)
# could write at a subdirectory of <root>, and cut git off from the developer's
# own config (for example a url.<ssh>.insteadOf rewrite must not change a test).
# HOME becomes a fake "real home" that tests can plant a sentinel in. Call it
# after common_setup (which already sandboxes SKILLS_DIR and AGENTS_DIR).
grid_env_isolate() {
  local root="$1"
  mkdir -p "$root/home" "$root/state" "$root/launch" "$root/systemd" "$root/claude" "$root/harness"
  export HOME="$root/home"
  export GRID_STATE_DIR="$root/state"
  export LAUNCH_AGENTS_DIR="$root/launch"
  export SYSTEMD_USER_DIR="$root/systemd"
  export CLAUDE_CONFIG_DIR="$root/claude"
  export GRID_HARNESS_HOME="$root/harness"
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_CONFIG_SYSTEM=/dev/null
  # file:// sources are only legal behind this flag (tests only).
  export GRID_ALLOW_FILE=1
  # GRID_LOCK_ALLOW_SHALLOW: CI sets it for the gate step, and it would turn the lock tests' shallow
  # case into a skip.
  unset GRID_DIR GRID_HOST GRID_BASELINE GRID_DRY_HOME GRID_SKIP_CATALOG GRID_SKIP_AUDIT GRID_LOCK_ALLOW_SHALLOW
}

# --- python helpers ------------------------------------------------------------
# tree_digest <dir>: sorted relative paths plus content hashes (and symlink
# targets) on stdout, so two calls can be compared for "byte-identical before
# and after". Prints nothing for an empty directory. One row per path: a backslash or
# newline in a name is escaped ("\\" / "\n") so a newline-named file stays one row.
# <dir>/.git/index is skipped: git rewrites it on a status refresh (the NF-046 hypothesis),
# which is a stat-cache update, not a change to the tree.
tree_digest() {
  python3 -B -c '
import hashlib, os, sys
top = sys.argv[1]
rows = []
def esc(text):
    return text.replace("\\", "\\\\").replace("\n", "\\n")
for root, dirs, files in os.walk(top):
    for name in dirs + files:
        full = os.path.join(root, name)
        rel = os.path.relpath(full, top)
        if rel == os.path.join(".git", "index"):
            continue
        if os.path.islink(full):
            rows.append("l %s %s" % (esc(rel), esc(os.readlink(full))))
        elif os.path.isfile(full):
            with open(full, "rb") as fh:
                rows.append("f %s %s" % (esc(rel), hashlib.sha256(fh.read()).hexdigest()))
        else:
            rows.append("d %s" % esc(rel))
print("\n".join(sorted(rows)))
' "$1"
}

# tree_digest_changed <before> <after>: given two tree_digest outputs, prints one line per
# path that was added, removed or changed ("<change> <kind> <path>": change is added, removed
# or modified; kind is the tree_digest row type f, l or d; the path keeps the tree_digest
# escaping, so a newline name stays on one line). Content hashes and file content are never
# printed. For failure diagnostics next to a `[ "$after" = "$before" ]` assert.
tree_digest_changed() {
  python3 -B -c '
import sys
def rows(text):
    out = {}
    for line in text.splitlines():
        kind, _, rest = line.partition(" ")
        if kind == "f":                           # "f <path> <sha256>": the hash is the value
            name, _, digest = rest.rpartition(" ")
        else:                                     # "l <path> <target>" / "d <path>": whole row
            name, digest = rest, ""
        out[(kind, name)] = digest
    return out
a, b = rows(sys.argv[1]), rows(sys.argv[2])
for key in sorted(set(a) | set(b), key=lambda k: (k[1], k[0])):
    if key not in a:
        change = "added"
    elif key not in b:
        change = "removed"
    elif a[key] != b[key]:
        change = "modified"
    else:
        continue
    print("%s %s %s" % (change, key[0], key[1]))
' "$1" "$2"
}

# file_id <path>: prints st_ino:st_mtime_ns. A rewrite through os.replace always
# changes the inode, so equality proves "not rewritten" even on a coarse-timestamp
# filesystem.
file_id() {
  python3 -B -c '
import os, sys
st = os.stat(sys.argv[1])
print("%d:%d" % (st.st_ino, st.st_mtime_ns))
' "$1"
}

# --- fixtures ---------------------------------------------------------------------
# _fixture_git_identity <repo>: a commit identity local to the repo (the global
# git config is /dev/null in the tests, so there is no other).
_fixture_git_identity() {
  git -C "$1" config user.email test@example.com
  git -C "$1" config user.name Test
  git -C "$1" config commit.gpgsign false
}

# make_upstream <dir>: a git repo that stands in for an upstream skills repo.
#   skills/alpha/SKILL.md, skills/alpha/run.sh (executable), nested/cat/beta/SKILL.md
# It allows partial-clone and fetch-by-sha so later groups can fetch from it.
make_upstream() {
  local dir="$1"
  mkdir -p "$dir/skills/alpha" "$dir/nested/cat/beta"
  git -C "$dir" init -q
  _fixture_git_identity "$dir"
  git -C "$dir" config uploadpack.allowFilter true
  git -C "$dir" config uploadpack.allowAnySHA1InWant true
  printf -- '---\nname: alpha\ndescription: Fixture skill alpha\n---\nAlpha body.\n' > "$dir/skills/alpha/SKILL.md"
  printf '#!/bin/sh\necho alpha\n' > "$dir/skills/alpha/run.sh"
  chmod +x "$dir/skills/alpha/run.sh"
  printf -- '---\nname: beta\ndescription: Fixture skill beta\n---\nBeta body.\n' > "$dir/nested/cat/beta/SKILL.md"
  git -C "$dir" add skills nested
  git -C "$dir" commit -q -m "fixture upstream"
}

# make_grid_fixture <grid> <upstream>: a parent grid repo with one source, `up`.
#   - copies scripts/grid, scripts/wire.sh and the whole scripts/lib/ from the real
#     repo, plus policy.yaml, CURATION.md, scripts/audit.py and scripts/audit.sh
#     when they exist (wire.sh calls audit.sh once policy.yaml exists)
#   - NO .gitmodules (so the scanner makes no source checks against file:// URLs)
#   - repos/up is a clone of <upstream>, registered in the parent index as a gitlink
#     (mode 160000) with `git update-index --add --cacheinfo`
#   - grid.yaml names source `up` with url file://<upstream>; the baseline file
#     baseline-submodules.example.txt holds the single line `up`
# $REPO_ROOT comes from helpers/setup.bash.
make_grid_fixture() {
  local grid="$1" upstream="$2" f sha
  mkdir -p "$grid/scripts" "$grid/repos"
  cp "$REPO_ROOT/scripts/grid" "$REPO_ROOT/scripts/wire.sh" "$grid/scripts/"
  cp -R "$REPO_ROOT/scripts/lib" "$grid/scripts/lib"
  for f in policy.yaml CURATION.md; do
    [ -f "$REPO_ROOT/$f" ] && cp "$REPO_ROOT/$f" "$grid/$f"
  done
  for f in audit.py audit.sh; do
    [ -f "$REPO_ROOT/scripts/$f" ] && cp "$REPO_ROOT/scripts/$f" "$grid/scripts/$f"
  done
  # A bytecode cache copied from the real scripts/lib must never reach a fixture.
  find "$grid/scripts" -name __pycache__ -type d -prune -exec rm -rf {} +
  printf 'up\n' > "$grid/baseline-submodules.example.txt"
  printf 'version: 1\nsources:\n  up:\n    url: file://%s\nwired:\n  baseline: baseline-submodules.example.txt\n' \
    "$upstream" > "$grid/grid.yaml"
  git -C "$grid" init -q
  _fixture_git_identity "$grid"
  git clone -q "file://$upstream" "$grid/repos/up"
  sha=$(git -C "$grid/repos/up" rev-parse HEAD)
  git -C "$grid" update-index --add --cacheinfo "160000,$sha,repos/up"
}

# fixture_advance <grid> <upstream>: move repos/up to the upstream's current HEAD
# and stage the matching pointer bump, the way a maintainer bumping a submodule
# does. (Without the bump a moved checkout is a lock error, exit 2.)
fixture_advance() {
  local grid="$1" upstream="$2" sha
  git -C "$grid/repos/up" fetch -q origin
  sha=$(git -C "$upstream" rev-parse HEAD)
  git -C "$grid/repos/up" checkout -q "$sha"
  git -C "$grid" update-index --add --cacheinfo "160000,$sha,repos/up"
}
