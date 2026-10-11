#!/usr/bin/env bats
# Tests for CURATION.md (change `vetting`, group 4).
#
# Runs in CI WITHOUT any submodule content and without a personal baseline: it only
# reads tracked files (CURATION.md, policy.yaml, .gitmodules, the example baseline).
# The audit of the wired content itself is `scripts/audit.sh --gate`, run by gate.sh.

load helpers/setup

setup() {
  common_setup
  AUDIT="$REPO_ROOT/scripts/audit.py"
  EXAMPLE="$REPO_ROOT/baseline-submodules.example.txt"
  # audit.py imports scripts/lib/miniyaml.py; keep that from leaving bytecode in the tree.
  export PYTHONDONTWRITEBYTECODE=1
}

teardown() {
  common_teardown
}

# baseline_names -> one repo name per line, from audit.baseline_repos() itself
# (imported, not re-parsed with awk, so typed entries like `project:core` and
# subtractions are skipped exactly as the scanner skips them).
baseline_names() {
  python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import audit; print("\n".join(sorted(audit.baseline_repos(sys.argv[2]))))' \
    "$REPO_ROOT/scripts" "$EXAMPLE"
}

@test "CURATION.md exists at the repo root and is non-empty" {
  [ -s "$REPO_ROOT/CURATION.md" ]
}

@test "audit.py parses the CURATION.md allowlist (an empty scan exits 0, not 2)" {
  empty="$(mktemp -d)"
  run python3 "$AUDIT" --root "$REPO_ROOT" --grid-dir "$REPO_ROOT" "$empty"
  rmdir "$empty"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "every audit-allow entry has a reason of real length" {
  # load_allowlist enforces the field rules (exit 2 on a missing rule/path/contains/
  # sha256/reason, at least 10 chars). AllowEntry does not keep the reason, so read
  # the block with the scanner's own YAML reader and hold every reason to a real
  # sentence (40+ chars), and the block to be non-empty.
  run python3 -c '
import sys
sys.path.insert(0, sys.argv[1] + "/scripts"); sys.path.insert(0, sys.argv[1] + "/scripts/lib")
import audit, miniyaml
policy = audit.Policy(sys.argv[1] + "/policy.yaml")
path = sys.argv[1] + "/CURATION.md"
assert audit.load_allowlist(path, policy), "audit-allow block is empty"
lines = open(path, encoding="utf-8").read().split("\n")
start = lines.index("```yaml audit-allow") + 1
end = lines.index("```", start)
entries = miniyaml.loads("\n".join(lines[start:end]))
for e in entries:
    assert len(str(e["reason"])) >= 40, "short reason: %r" % (e,)
print(len(entries), "entries")
' "$REPO_ROOT"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "the example baseline names at least one repo (the loop below is not vacuous)" {
  run baseline_names
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "every repo in the example baseline has a '### repos/<name>' heading in CURATION.md" {
  names="$(baseline_names)"
  [ -n "$names" ]
  missing=""
  for n in $names; do
    command grep -qx "### repos/$n" "$REPO_ROOT/CURATION.md" || missing="$missing $n"
  done
  [ -z "$missing" ] || { echo "no heading for:$missing"; false; }
}

@test "every repo in the example baseline has a .gitmodules URL that passes --check-url" {
  names="$(baseline_names)"
  [ -n "$names" ]
  for n in $names; do
    url="$(git config -f "$REPO_ROOT/.gitmodules" --get "submodule.repos/$n.url")"
    [ -n "$url" ] || { echo "no .gitmodules url for repos/$n"; false; }
    run python3 "$AUDIT" --root "$REPO_ROOT" --grid-dir "$REPO_ROOT" --check-url "$url"
    echo "repos/$n: $url -> $status $output"
    [ "$status" -eq 0 ]
  done
}

@test "no CURATION.md heading claims a repo that policy.yaml does not allow" {
  # A heading is a trust claim: every `### repos/<name>` needs a submodule URL that
  # --check-url accepts, so the doc and the source allowlist cannot drift apart.
  for n in $(command sed -n 's/^### repos\/\([^[:space:]]*\)[[:space:]]*$/\1/p' "$REPO_ROOT/CURATION.md"); do
    url="$(git config -f "$REPO_ROOT/.gitmodules" --get "submodule.repos/$n.url")"
    [ -n "$url" ] || { echo "heading repos/$n has no .gitmodules entry"; false; }
    run python3 "$AUDIT" --root "$REPO_ROOT" --grid-dir "$REPO_ROOT" --check-url "$url"
    echo "repos/$n: $url -> $status $output"
    [ "$status" -eq 0 ]
  done
}
