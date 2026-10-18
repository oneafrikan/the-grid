#!/usr/bin/env bats
# WP-072: the loop setup docs must be safe and true to follow. These guard the four records
# (R25.qa.F4, F5, F8, F13) in the two docs that carry the key-handling steps:
#   docs/uplift-runbook.md                       (the operator runbook)
#   automation-factory/docs/secure-agent-loop.md (the generic playbook)
# The loop INSTANCE is retired (see _retired/issue-loop/RETIRED.md); the automation-factory
# pattern and this playbook are not, so the docs stay correct rather than being deleted.

load helpers/setup

RUNBOOK=docs/uplift-runbook.md
SECURE=automation-factory/docs/secure-agent-loop.md

# common_setup sandboxes every home-derived dir; these tests only read the repo, but the
# sandbox (and its tripwire) is the house rule for every test file.
setup() {
  common_setup
  cd "$REPO_ROOT"
}

teardown() {
  common_teardown
}

# --- F5: "must print nothing" has to be able to fail --------------------------------------

@test "F5: neither doc uses the blind find -perm -077 permission check" {
  # -perm -077 means "group AND other bits all set"; a 644 or 640 key slips through it
  ! grep -rn -e '-perm -077' docs automation-factory || false
  grep -q -e '-perm /077' "$RUNBOOK"
  grep -q -e '-perm /077' "$SECURE"
}

@test "F5: the documented find form flags a loose key, the old form does not (functional)" {
  # GNU find only: /MODE is a GNU extension and the loop box is Linux
  find --version 2>/dev/null | grep -q GNU || skip "GNU find required"
  d="$BATS_TEST_TMPDIR/keys"
  mkdir -p "$d"
  for m in 644 640 604 666 600; do
    : > "$d/mode-$m"
    chmod "$m" "$d/mode-$m"
  done
  # documented form: prints every file that has any group/other bit, and not the 600 one
  out="$(find "$d" -type f -perm /077)"
  [[ "$out" == *mode-644* ]]
  [[ "$out" == *mode-640* ]]
  [[ "$out" == *mode-604* ]]
  [[ "$out" == *mode-666* ]]
  [[ "$out" != *mode-600* ]]
  # the form the docs used to carry stays blind to a 644 key (that is the defect)
  [ -z "$(find "$d/mode-644" -perm -077)" ]
}

@test "F5: the secure playbook sets umask and the config dir in the block that writes the env file" {
  # one shell block: re-enter as the loop user, mode-700 config dir, umask 077, then the heredoc
  block="$(awk '/^### Step 6 /{f=1} f&&/^```bash/{b=1;next} b&&/^```/{exit} b' "$SECURE")"
  [[ "$block" == *"sudo -iu <loop-user>"* ]]
  [[ "$block" == *"umask 077"* ]]
  [[ "$block" == *"install -d -m 700 ~/.config/the-grid"* ]]
  [[ "$block" == *"cat > ~/.config/the-grid/issue-loop.env"* ]]
}

# --- F4: no step may hand key placement to a script that exists nowhere ---------------------

@test "F4: the runbook does not delegate key placement to an unnamed script" {
  ! grep -n -E '<setup-script>|sudo bash <' "$RUNBOOK" || false
  grep -q 'sudo install -o <loop-user> -g <loop-user> -m 600' "$RUNBOOK"
  grep -q 'shred -u' "$RUNBOOK"
}

@test "F4: the playbook says the one-shot setup script is private and not shipped" {
  grep -q -i 'not shipped' "$SECURE"
  # the manual route creates the config dir before installing the key into it
  grep -q 'install -d -m 700 ~<loop-user>/.config/the-grid' "$SECURE"
}

# --- F8: secret-handling nits ------------------------------------------------------------------

@test "F8: the token minter is never copied through /tmp" {
  ! grep -n '/tmp/gh-app-token' "$RUNBOOK" "$SECURE" || false
  grep -q 'install -m 755' "$RUNBOOK"
  grep -q 'install -m 755' "$SECURE"
}

@test "F8: the App key is copied into a mode-700 directory, not to a default-mode ~/app.pem" {
  ! grep -n -E 'scp .*:~/app\.pem|chmod 600 ~/app\.pem' "$RUNBOOK" "$SECURE" || false
  grep -q "install -d -m 700 ~/keys" "$RUNBOOK"
  grep -q "install -d -m 700 ~/keys" "$SECURE"
}

@test "F8: the runbook tells the reader to check Anthropic's current install command before piping it to bash" {
  # the pipe-to-bash line is the one that must carry the warning (the playbook already does)
  grep -n -B2 'claude.ai/install.sh' "$RUNBOOK" | grep -q -i "check.*current"
  grep -n -B2 'claude.ai/install.sh' "$SECURE" | grep -q -i "check.*current"
}

# --- F13: the status text matches the code ------------------------------------------------------

@test "F13: neither doc says the loop code is unmerged" {
  ! grep -n -E 'specified, not yet merged|only exist once the `loops` change is merged' "$RUNBOOK" "$SECURE" || false
  # the four components really exist (in the quarantine for the instance, in the pattern)
  [ -f _retired/issue-loop/loop/run-issues.sh ]
  [ -f _retired/issue-loop/scripts/lib/gh-app-token.sh ]
  [ -f _retired/issue-loop/scripts/instantiate.sh ]
  [ -f scripts/lib/render-schedule.sh ]
}

@test "F13: the runbook keeps the retired banner and does not add a second one" {
  [ "$(grep -c 'RETIRED - do not deploy' "$RUNBOOK")" -eq 1 ]
  head -n 1 "$RUNBOOK" | grep -q 'RETIRED - do not deploy'
}

@test "F13: the steps that copy the minter name its real (quarantined) location" {
  # the file moved under WP-043; a step that says "copy scripts/lib/gh-app-token.sh from your
  # checkout" would send the reader to a path that does not exist
  [ ! -e scripts/lib/gh-app-token.sh ]
  grep -q 'scp .*_retired/issue-loop/scripts/lib/gh-app-token.sh' "$RUNBOOK"
  grep -q '_retired/issue-loop/scripts/lib/gh-app-token.sh' "$SECURE"
  ! grep -n -E 'checkout>/scripts/lib/gh-app-token\.sh' "$RUNBOOK" "$SECURE" || false
}

@test "the runbook does not tell a reader to recompose only three public projects" {
  # four example configs exist (see test_docs_accuracy.bats); the recompose list must match
  ! grep -n -i -E 'only the public three|three public' "$RUNBOOK" || false
}
