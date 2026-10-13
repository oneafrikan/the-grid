#!/usr/bin/env bats
# Tests for `grid lock` and `grid lock --check`, group 2 of change
# `manifest-lock-install`: the content-hash helpers, lock generation from real
# submodule checkouts, and the check.
#
# Every fixture is a throwaway git repo built inside the test (see
# helpers/grid_fixture.bash). Nothing touches the network, the real ~/.grid or
# the real ~/.claude. These tests verify my own implementation (a self-check);
# independent verification is for qa-engineer / sdet.

load helpers/setup
load helpers/grid_fixture

setup() {
  common_setup
  T=$(mktemp -d)
  grid_env_isolate "$T/env"
  U="$T/upstream"
  G="$T/grid"
  make_upstream "$U"
  make_grid_fixture "$G" "$U"
  GRID_BIN="$G/scripts/grid"
}

teardown() {
  rm -rf "$T"
  common_teardown
}

# lock [ARGS...]: run `grid lock` against the fixture grid.
# python3 -B: never write bytecode, so the fixture tree stays free of __pycache__.
lock() { python3 -B "$GRID_BIN" --grid-dir "$G" lock "$@"; }

# lock_field NAME FIELD: print one field of the named entry in grid.lock.
lock_field() {
  python3 -B -c '
import json, sys
doc = json.load(open(sys.argv[1]))
print([e for e in doc["entries"] if e["name"] == sys.argv[2]][0][sys.argv[3]])
' "$G/grid.lock" "$1" "$2"
}

# upstream_commit MSG: commit everything pending in the upstream repo.
upstream_commit() {
  git -C "$U" add -A
  git -C "$U" commit -q -m "$1"
}

# ref_hash DIR: an INDEPENDENT re-implementation of the design's content hash,
# written from design.md ("File formats") and not from scripts/grid, so the
# tests do not just compare the implementation with itself.
ref_hash() {
  python3 -B -c '
import hashlib, os, sys
top = sys.argv[1]
rows = []
for root, dirs, files in os.walk(top):
    if "__pycache__" in root.split(os.sep):
        continue
    for name in dirs + files:
        full = os.path.join(root, name)
        if os.path.isdir(full) and not os.path.islink(full):
            continue
        if name == ".DS_Store" or name.endswith(".pyc"):
            continue
        rel = os.path.relpath(full, top)
        if os.path.islink(full):
            cls, data = "l", os.readlink(full).encode()
        else:
            cls = "x" if os.stat(full).st_mode & 0o111 else "-"
            data = open(full, "rb").read()
        rows.append((rel.encode(), cls, hashlib.sha256(data).hexdigest()))
rows.sort()
h = hashlib.sha256()
for rel, cls, digest in rows:
    h.update(("%s " % cls).encode() + rel + (" %s\n" % digest).encode())
print("sha256:" + h.hexdigest())
' "$1"
}

# --- (a) lock content ------------------------------------------------------------

@test "lock of the fixture baseline is non-empty and holds alpha and beta" {
  # SKILLS_DIR is exported by common_setup; the lock must ignore it and read the
  # links wire.sh makes under the temp home (<tmp>/home/.claude/skills).
  run lock
  [ "$status" -eq 0 ]
  grep -q '"name": "alpha"' "$G/grid.lock"
  grep -q '"name": "beta"' "$G/grid.lock"
  # The inherited SKILLS_DIR / AGENTS_DIR were not written to.
  [ -z "$(tree_digest "$MOCK_SKILLS")" ]
  [ -z "$(tree_digest "$MOCK_AGENTS")" ]
}

@test "lock content: sorted entries, kind skill, 40-hex sha and tree, sha256 hash" {
  run lock
  [ "$status" -eq 0 ]
  run python3 -B -c '
import json, re, sys
doc = json.load(open(sys.argv[1]))
assert doc["lockVersion"] == 1
entries = doc["entries"]
assert [e["name"] for e in entries] == ["alpha", "beta"], entries
for e in entries:
    assert sorted(e) == ["hash", "kind", "name", "path", "sha", "source", "tree"], e
    assert e["kind"] == "skill" and e["source"] == "up"
    assert re.fullmatch(r"[0-9a-f]{40}", e["sha"]) and re.fullmatch(r"[0-9a-f]{40}", e["tree"])
    assert re.fullmatch(r"sha256:[0-9a-f]{64}", e["hash"])
assert entries[0]["path"] == "skills/alpha" and entries[1]["path"] == "nested/cat/beta"
print("ok")
' "$G/grid.lock"
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
  # 2-space indent, sorted keys, trailing newline.
  [ "$(head -c 1 "$G/grid.lock")" = "{" ]
  [ "$(tail -c 2 "$G/grid.lock" | od -An -c | tr -d ' ')" = '}\n' ]
  grep -q '^  "entries": \[' "$G/grid.lock"
}

@test "lock sha is the gitlink commit, tree is rev-parse sha:path" {
  run lock
  [ "$status" -eq 0 ]
  [ "$(lock_field alpha sha)" = "$(git -C "$U" rev-parse HEAD)" ]
  [ "$(lock_field alpha tree)" = "$(git -C "$U" rev-parse HEAD:skills/alpha)" ]
  [ "$(lock_field beta tree)" = "$(git -C "$U" rev-parse HEAD:nested/cat/beta)" ]
}

@test "content hash agrees with an independent implementation, executable bit and dir symlink included" {
  # alpha already has an executable run.sh. Add a directory symlink that stays
  # inside the skill: it must be hashed as class l, not followed.
  mkdir -p "$U/skills/alpha/sub"
  printf 'x\n' > "$U/skills/alpha/sub/f.txt"
  ln -s sub "$U/skills/alpha/dirlink"
  upstream_commit "dir symlink"
  fixture_advance "$G" "$U"
  run lock
  [ "$status" -eq 0 ]
  [ "$(lock_field alpha hash)" = "$(ref_hash "$G/repos/up/skills/alpha")" ]
  [ "$(lock_field beta hash)" = "$(ref_hash "$G/repos/up/nested/cat/beta")" ]
  # The independent hash really did see the link as a link: removing it changes the hash.
  before=$(lock_field alpha hash)
  git -C "$U" rm -q skills/alpha/dirlink
  upstream_commit "drop link"
  fixture_advance "$G" "$U"
  run lock
  [ "$status" -eq 0 ]
  [ "$(lock_field alpha hash)" != "$before" ]
  [ "$(lock_field alpha hash)" = "$(ref_hash "$G/repos/up/skills/alpha")" ]
}

@test "the execute bit is part of the hash" {
  run lock
  before=$(lock_field alpha hash)
  chmod -x "$U/skills/alpha/run.sh"
  git -C "$U" update-index --chmod=-x skills/alpha/run.sh
  upstream_commit "drop exec bit"
  fixture_advance "$G" "$U"
  run lock
  [ "$status" -eq 0 ]
  [ "$(lock_field alpha hash)" != "$before" ]
}

@test "a second run is byte-identical and does not rewrite the file" {
  run lock
  [ "$status" -eq 0 ]
  cp "$G/grid.lock" "$T/first.lock"
  id=$(file_id "$G/grid.lock")
  run lock
  [ "$status" -eq 0 ]
  cmp "$T/first.lock" "$G/grid.lock"
  [ "$(file_id "$G/grid.lock")" = "$id" ]
}

# --- (b) refusals (exit 2, nothing written) ------------------------------------------

@test "a dirty skill dir exits 2 naming the source and writes nothing" {
  printf 'edited\n' >> "$G/repos/up/skills/alpha/SKILL.md"
  run lock
  [ "$status" -eq 2 ]
  [[ "$output" == *"repos/up"* ]]
  [[ "$output" == *"skills/alpha"* ]]
  [ ! -e "$G/grid.lock" ]
}

@test "a checkout at another commit than the recorded one exits 2 naming the source" {
  printf 'more\n' >> "$U/skills/alpha/SKILL.md"
  upstream_commit "second"
  git -C "$G/repos/up" fetch -q origin
  git -C "$G/repos/up" checkout -q "$(git -C "$U" rev-parse HEAD)"
  # The parent pointer is NOT bumped.
  run lock
  [ "$status" -eq 2 ]
  [[ "$output" == *"repos/up"* ]]
  [ ! -e "$G/grid.lock" ]
}

@test "a symlink escaping the skill dir exits 2 naming the file" {
  ln -s ../../../outside "$U/skills/alpha/escape"
  upstream_commit "escaping link"
  fixture_advance "$G" "$U"
  run lock
  [ "$status" -eq 2 ]
  [[ "$output" == *"escape"* ]]
  [[ "$output" == *"points outside"* ]]
  [ ! -e "$G/grid.lock" ]
}

@test "an absolute symlink target also counts as escaping" {
  ln -s /etc/hosts "$U/skills/alpha/abs"
  upstream_commit "absolute link"
  fixture_advance "$G" "$U"
  run lock
  [ "$status" -eq 2 ]
  [[ "$output" == *"abs"* ]]
}

@test "a skill directory named 'has space' makes lock exit 2 naming it" {
  mkdir -p "$U/skills/has space"
  printf -- '---\nname: has space\ndescription: x\n---\n' > "$U/skills/has space/SKILL.md"
  upstream_commit "unsafe name"
  fixture_advance "$G" "$U"
  run lock
  [ "$status" -eq 2 ]
  [[ "$output" == *"has space"* ]]
  [ ! -e "$G/grid.lock" ]
}

@test "a gitlink (mode 160000) inside a skill exits 2 naming the path" {
  git -C "$U" update-index --add --cacheinfo "160000,$(git -C "$U" rev-parse HEAD),skills/alpha/inner"
  git -C "$U" commit -q -m "nested submodule"
  fixture_advance "$G" "$U"
  run lock
  [ "$status" -eq 2 ]
  [[ "$output" == *"inner"* ]]
  [[ "$output" == *"nested submodule"* ]]
  [ ! -e "$G/grid.lock" ]
}

# --- (c) litter is not content ------------------------------------------------------------

# track_excluded REL: commit a regular file REL (relative to skills/alpha) upstream and
# bump repos/up to it, then run `grid lock` (status/output for the caller).
track_excluded() {
  mkdir -p "$U/skills/alpha/$(dirname "$1")"
  printf 'junk' > "$U/skills/alpha/$1"
  upstream_commit "tracked $1"
  fixture_advance "$G" "$U"
  run lock
}

@test "a tracked .DS_Store makes lock exit 2 naming the file, and nothing is written" {
  track_excluded .DS_Store
  [ "$status" -eq 2 ]
  [[ "$output" == *".DS_Store"* ]]
  [ ! -e "$G/grid.lock" ]
}

@test "a tracked __pycache__/x.pyc makes lock exit 2 naming the file" {
  track_excluded __pycache__/x.pyc
  [ "$status" -eq 2 ]
  [[ "$output" == *"__pycache__/x.pyc"* ]]
}

@test "a tracked sourceless .pyc makes lock exit 2 naming the file" {
  track_excluded helper.pyc
  [ "$status" -eq 2 ]
  [[ "$output" == *"helper.pyc"* ]]
}

@test "a tracked excluded file also fails lock --check" {
  run lock
  [ "$status" -eq 0 ]
  track_excluded helper.pyc
  run lock --check
  [ "$status" -eq 2 ]
  [[ "$output" == *"helper.pyc"* ]]
}

@test ".DS_Store and __pycache__/x.pyc created on disk after checkout do not change the hash or dirty the skill" {
  run lock
  [ "$status" -eq 0 ]
  # Created on disk after checkout: neither a dirty skill dir nor a hash change.
  mkdir -p "$G/repos/up/nested/cat/beta/__pycache__"
  printf 'junk' > "$G/repos/up/nested/cat/beta/.DS_Store"
  printf 'junk' > "$G/repos/up/nested/cat/beta/__pycache__/y.pyc"
  beta_before=$(lock_field beta hash)
  run lock
  [ "$status" -eq 0 ]
  [ "$(lock_field beta hash)" = "$beta_before" ]
  # And the independent disk-side hash agrees, litter and all.
  [ "$(ref_hash "$G/repos/up/nested/cat/beta")" = "$beta_before" ]
}

# --- (d) typed entries, other lock kinds ----------------------------------------------------

@test "typed baseline entries (rules:, harness:, project:) produce the same lock" {
  run lock
  [ "$status" -eq 0 ]
  cp "$G/grid.lock" "$T/plain.lock"
  printf 'rules:sql\nharness:codex\nproject:core\n-project:other\n-rules:x\n' >> "$G/baseline-submodules.example.txt"
  rm "$G/grid.lock"
  run lock
  [ "$status" -eq 0 ]
  cmp "$T/plain.lock" "$G/grid.lock"
}

@test "lock --check reads a lock holding a kind rule entry with a notice and exits 0" {
  run lock
  [ "$status" -eq 0 ]
  python3 -B -c '
import json, sys
doc = json.load(open(sys.argv[1]))
doc["entries"].append({"kind": "rule", "name": "sql-pack"})
open(sys.argv[1], "w").write(json.dumps(doc, indent=2, sort_keys=True) + "\n")
' "$G/grid.lock"
  run lock --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"kind 'rule'"* ]]
}

# --- (e) --check ---------------------------------------------------------------------------------

@test "lock --check exits 0 on a fresh lock" {
  run lock
  run lock --check
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "lock --check exits 1 naming the skill when content changed and the lock was not regenerated" {
  run lock
  printf 'changed body\n' >> "$U/skills/alpha/SKILL.md"
  upstream_commit "alpha changed"
  fixture_advance "$G" "$U"
  run lock --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"lock changed alpha"* ]]
  # alpha's hash differs; beta's content is the same, only the commit moved.
  [[ "$output" == *"lock changed alpha up: "*"hash"* ]]
  beta_line=$(printf '%s\n' "$output" | grep '^lock changed beta')
  [[ "$beta_line" != *"hash"* ]]
  # Regenerating fixes it.
  run lock
  [ "$status" -eq 0 ]
  run lock --check
  [ "$status" -eq 0 ]
}

@test "lock --check lists added and removed skills" {
  run lock
  mkdir -p "$U/skills/gamma"
  printf -- '---\nname: gamma\ndescription: g\n---\n' > "$U/skills/gamma/SKILL.md"
  git -C "$U" rm -q -r nested/cat/beta
  upstream_commit "add gamma, drop beta"
  fixture_advance "$G" "$U"
  run lock --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"lock added gamma"* ]]
  [[ "$output" == *"lock removed beta"* ]]
}

@test "lock --check exits 3 with the message when repos/up/.git is absent" {
  run lock
  [ "$status" -eq 0 ]
  mv "$G/repos/up/.git" "$G/repos/up/.git.away"
  run lock --check
  [ "$status" -eq 3 ]
  [[ "$output" == *"grid: lock --check not possible here: repos/up is not a checkout"* ]]
}

@test "lock --check exits 1 naming a baseline repo that has no sources entry" {
  run lock
  printf 'ghost\n' >> "$G/baseline-submodules.example.txt"
  run lock --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"manifest source-missing ghost"* ]]
}

@test "lock --check exits 1 printing both URLs when grid.yaml and .gitmodules differ" {
  run lock
  printf '[submodule "repos/up"]\n\tpath = repos/up\n\turl = https://example.com/other.git\n' > "$G/.gitmodules"
  run lock --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"manifest url up"* ]]
  [[ "$output" == *"file://$U"* ]]
  [[ "$output" == *"https://example.com/other.git"* ]]
}

@test "lock --check exits 1 for a non-https source URL (file:// needs GRID_ALLOW_FILE=1)" {
  run lock
  GRID_ALLOW_FILE= run lock --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"manifest url up"* ]]
  [[ "$output" == *"not https"* ]]
}

# --- (f) isolation (G1) --------------------------------------------------------------------------

@test "lock run with HOME at an empty temp dir leaves that dir empty" {
  local empty="$T/empty-home"
  mkdir -p "$empty"
  HOME="$empty" run lock
  [ "$status" -eq 0 ]
  [ -z "$(find "$empty" -mindepth 1)" ]
}

@test "G1: lock leaves a sentinel in the fake real home byte-identical and creates nothing else there" {
  mkdir -p "$HOME/.claude/skills" "$HOME/.grid"
  printf 'sentinel\n' > "$HOME/.claude/skills/sentinel.txt"
  printf '{"hooks":{}}\n' > "$HOME/.claude/settings.json"
  before=$(tree_digest "$HOME")
  id=$(file_id "$HOME/.claude/skills/sentinel.txt")
  run lock
  [ "$status" -eq 0 ]
  run lock --check
  [ "$status" -eq 0 ]
  [ "$(tree_digest "$HOME")" = "$before" ]
  [ "$(file_id "$HOME/.claude/skills/sentinel.txt")" = "$id" ]
  # No state dir content either (lock never touches ~/.grid).
  [ -z "$(find "$GRID_STATE_DIR" -mindepth 1)" ]
}

@test "lock through a symlinked grid path gives the same lock as through the real path" {
  run lock
  [ "$status" -eq 0 ]
  cp "$G/grid.lock" "$T/real.lock"
  rm "$G/grid.lock"
  ln -s "$G" "$T/grid-link"
  run python3 -B "$T/grid-link/scripts/grid" --grid-dir "$T/grid-link" lock
  [ "$status" -eq 0 ]
  cmp "$T/real.lock" "$G/grid.lock"
  run python3 -B "$T/grid-link/scripts/grid" --grid-dir "$T/grid-link" lock --check
  [ "$status" -eq 0 ]
}

@test "lock leaves no __pycache__ in the fixture grid" {
  run lock
  [ "$status" -eq 0 ]
  [ -z "$(find "$G" -name __pycache__ -not -path '*/repos/up/*')" ]
}

# --- (h) lock integrity (private WP-033) ---------------------------------------------------------------

# edit_lock PYCODE: run PYCODE (python, `doc` is the parsed grid.lock) and write it back.
edit_lock() {
  python3 -B -c '
import json, sys
path = sys.argv[1]
doc = json.load(open(path))
exec(sys.argv[2])
json.dump(doc, open(path, "w"), indent=2, sort_keys=True)
open(path, "a").write("\n")
' "$G/grid.lock" "$1"
}

# orphan_commit: add a commit upstream on a branch that is then deleted, so no ref in the
# upstream reaches it. Sets ORPHAN to its sha and fetches it into repos/up with the pointer bumped.
orphan_commit() {
  git -C "$U" checkout -q -b scratch
  printf 'orphan\n' >> "$U/skills/alpha/SKILL.md"
  git -C "$U" commit -q -a -m "on a deleted branch"
  ORPHAN=$(git -C "$U" rev-parse HEAD)
  git -C "$U" checkout -q -
  git -C "$U" branch -q -D scratch
  git -C "$G/repos/up" fetch -q origin "$ORPHAN"
  git -C "$G/repos/up" checkout -q "$ORPHAN"
  git -C "$G" update-index --add --cacheinfo "160000,$ORPHAN,repos/up"
}

@test "lock of a sha that is not reachable from the declared ref exits 2 naming the source and sha" {
  orphan_commit
  run lock
  [ "$status" -eq 2 ]
  [[ "$output" == *"repos/up"* ]]
  [[ "$output" == *"${ORPHAN:0:12}"* ]]
  [ ! -e "$G/grid.lock" ]
}

@test "lock of a sha that a tag points at passes" {
  orphan_commit
  git -C "$U" tag v1 "$ORPHAN"
  git -C "$G/repos/up" fetch -q origin "refs/tags/v1:refs/tags/v1"
  run lock
  [ "$status" -eq 0 ]
  [ -f "$G/grid.lock" ]
}

@test "lock --check re-proves reachability" {
  run lock
  [ "$status" -eq 0 ]
  orphan_commit
  run lock --check
  [ "$status" -eq 2 ]
  [[ "$output" == *"${ORPHAN:0:12}"* ]]
}

@test "lock with the remote-tracking ref absent exits 2 with the fetch hint" {
  git -C "$G/repos/up" update-ref -d refs/remotes/origin/HEAD
  run lock
  [ "$status" -eq 2 ]
  [[ "$output" == *"fetch origin"* ]]
}

@test "a shallow checkout that cannot prove reachability: lock exits 2 mentioning shallow, lock --check skips with a notice" {
  run lock
  [ "$status" -eq 0 ]
  rm -rf "$G/repos/up"
  git clone -q --depth 1 "file://$U" "$G/repos/up"
  printf 'next\n' >> "$U/skills/alpha/SKILL.md"
  upstream_commit "tip moves on"
  tip=$(git -C "$U" rev-parse HEAD)
  git -C "$G/repos/up" fetch -q --depth 1 origin "$tip"
  git -C "$G/repos/up" checkout -q "$tip"
  git -C "$G" update-index --add --cacheinfo "160000,$tip,repos/up"
  run lock
  [ "$status" -eq 2 ]
  [[ "$output" == *"shallow"* ]]
  run lock --check
  [ "$status" -ne 2 ]
  [[ "$output" == *"shallow"* ]]
}

@test "a duplicate (name, source) entry in grid.lock is rejected by lock --check, exit 2 naming both entries" {
  run lock
  [ "$status" -eq 0 ]
  edit_lock 'e = dict(doc["entries"][0]); e["path"] = "skills/other"; doc["entries"].append(e)'
  run lock --check
  [ "$status" -eq 2 ]
  [[ "$output" == *"duplicate"* ]]
  [[ "$output" == *"entry 0"* ]]
  [[ "$output" == *"entry 2"* ]]
}

@test "a duplicate dest in grid.lock (same source and path under another name) is rejected, exit 2" {
  run lock
  [ "$status" -eq 0 ]
  edit_lock 'e = dict(doc["entries"][0]); e["name"] = "alpha-copy"; doc["entries"].append(e)'
  run lock --check
  [ "$status" -eq 2 ]
  [[ "$output" == *"duplicate"* ]]
  [[ "$output" == *"entry 0"* ]]
  [[ "$output" == *"entry 2"* ]]
}

@test "lock with no checkouts exits non-zero and leaves grid.lock byte-identical" {
  run lock
  [ "$status" -eq 0 ]
  before=$(cksum < "$G/grid.lock")
  rm -rf "$G/repos/up"
  mkdir "$G/repos/up"
  run lock
  [ "$status" -ne 0 ]
  [[ "$output" == *"repos/up"* ]]
  [ "$before" = "$(cksum < "$G/grid.lock")" ]
}

@test "lock that would write zero entries is refused and leaves grid.lock byte-identical" {
  run lock
  [ "$status" -eq 0 ]
  before=$(cksum < "$G/grid.lock")
  printf 'project:core\n' > "$G/baseline-submodules.example.txt"
  run lock
  [ "$status" -eq 2 ]
  [[ "$output" == *"0 entries"* ]]
  [ "$before" = "$(cksum < "$G/grid.lock")" ]
}

# add_second_source: grid.yaml and the baseline also name `up2`, which has NO checkout.
add_second_source() {
  python3 -B -c '
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace("wired:", "  up2:\n    url: file:///nonexistent/up2\nwired:", 1)
open(p, "w").write(s)
' "$G/grid.yaml"
  printf 'up\nup2\n' > "$G/baseline-submodules.example.txt"
}

@test "a baseline source without a checkout is refused by lock, naming it, and grid.lock is not written" {
  add_second_source
  run lock
  [ "$status" -eq 2 ]
  [[ "$output" == *"up2"* ]]
  [ ! -e "$G/grid.lock" ]
}

@test "lock --check with one missing checkout and one stale present source reports the stale one and names the skipped one" {
  run lock
  [ "$status" -eq 0 ]
  add_second_source
  edit_lock 'e = dict(doc["entries"][0]); e["name"] = "gamma"; e["source"] = "up2"; e["path"] = "skills/gamma"; doc["entries"].append(e)'
  printf 'changed body\n' >> "$U/skills/alpha/SKILL.md"
  upstream_commit "alpha changed"
  fixture_advance "$G" "$U"
  run lock --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"lock changed alpha"* ]]
  [[ "$output" == *"skipped repos/up2"* ]]
  # The skipped source is not reported as removed.
  [[ "$output" != *"gamma"* ]]
}

# --- (g) the real repo -------------------------------------------------------------------------------

@test "the committed grid.lock matches the real checkouts (or is not checkable here)" {
  # 0 where every source is checked out, 3 on a checkout without the submodules.
  run python3 -B "$REPO_ROOT/scripts/grid" --grid-dir "$REPO_ROOT" lock --check
  if [ "$status" -ne 0 ] && [ "$status" -ne 3 ]; then
    echo "status $status: $output" >&2
    false
  fi
  # Whatever the checkouts look like, the committed file itself must be readable.
  run python3 -B -c '
import json, sys
doc = json.load(open(sys.argv[1]))
assert doc["lockVersion"] == 1 and len(doc["entries"]) > 0
print(len(doc["entries"]))
' "$REPO_ROOT/grid.lock"
  [ "$status" -eq 0 ]
}
