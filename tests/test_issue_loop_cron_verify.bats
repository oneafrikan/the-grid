#!/usr/bin/env bats
# issue-loop: the per-repo cron line (instantiate.sh --cron-every, render-schedule every:N) and the
# optional fast verify (loop/verify.sh). Targets are temp repos; gh and claude are stubs; nothing
# is scheduled (the crontab stub-log assertion proves it).

bats_require_minimum_version 1.5.0
load helpers/setup
load helpers/stubs

INST="$BATS_TEST_DIRNAME/../scripts/instantiate.sh"
RS="$BATS_TEST_DIRNAME/../scripts/lib/render-schedule.sh"
PAT_DIR="$BATS_TEST_DIRNAME/../automation-factory/patterns/issue-loop"

setup() {
  common_setup
  T="$(mktemp -d)"
  T="$(cd "$T" && pwd -P)"
  export HOME="$T/home"
  mkdir -p "$HOME"
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com
  export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
  unset GRID_DIR
  make_stubs
  export STUB_GH_STORED_LOGIN=1
  REPO="$T/repo"
  git init -q -b main "$REPO"
  echo seed > "$REPO/README.md"
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m seed
}

teardown() {
  clean_stubs
  rm -rf "$T"
  common_teardown
}

@test "render_crontab_line every:N renders */N, rejects 0, 60 and junk, and systemd refuses it" {
  run bash "$RS" render_crontab_line every:15 "$T/logs/l.log" "$T/proj" bash loop/cron-run.sh
  [ "$status" -eq 0 ]
  [ "$output" = "*/15 * * * * mkdir -p $T/logs && cd $T/proj && bash loop/cron-run.sh >> $T/logs/l.log 2>&1" ]
  for bad in every:0 every:60 every:x every:; do
    run -2 --separate-stderr bash "$RS" render_crontab_line "$bad" "$T/l.log" "$T/proj" bash a
    [ -z "$output" ]
  done
  run -2 bash "$RS" render_systemd_timer d u.service every:5
}

@test "--cron-every prints one line with log and activation, writes cron.env, never calls crontab" {
  run bash "$INST" issue-loop "$REPO" --profile work --repo owner/name --project-context x --review-focus y \
    --cron-every 15 --cron-log "$T/logs/name.log"
  [ "$status" -eq 0 ]
  contains "$output" "*/15 * * * * mkdir -p $T/logs && cd $REPO && bash loop/cron-run.sh >> $T/logs/name.log 2>&1"
  contains "$output" "crontab"
  # the claude stub's dir was resolved at install time and baked in; cron.env stays out of version control
  grep -q "^export PATH='/usr/local/bin:/usr/bin:/bin.*$STUB_DIR" "$REPO/loop/cron.env"
  grep -q '^export HOME=' "$REPO/loop/cron.env"
  [ -x "$REPO/loop/cron-run.sh" ]
  refute grep -qE '^crontab ' "$STUB_LOG"
  # without the option: no cron output at all
  rm "$REPO/loop/cron.env"
  run bash "$INST" issue-loop "$REPO" --profile work --repo owner/name --project-context x --review-focus y
  [ "$status" -eq 0 ]
  lacks "$output" "Cron (printed"
  [ ! -e "$REPO/loop/cron.env" ]
}

@test "--cron-every works with --land direct, and is still refused for the interactive direct mode" {
  run bash "$INST" issue-loop "$REPO" --profile work --land direct --repo owner/name --project-context x --review-focus y \
    --cron-every 15 --cron-log "$T/logs/name.log"
  [ "$status" -eq 0 ]
  contains "$output" "*/15 * * * * mkdir -p $T/logs && cd $REPO && bash loop/cron-run.sh"
  grep -q "^MODE=\${MODE:-'direct'}" "$REPO/loop/loop.conf"
  rm -rf "$REPO/loop"
  run bash "$INST" issue-loop "$REPO" --profile personal --repo owner/name --project-context x --review-focus y --cron-every 15
  [ "$status" -ne 0 ]
  contains "$output" "needs the headless runner"
}

@test "--fast-verify sets VERIFY_CMD to loop/verify.sh and ships it; an explicit --verify-cmd wins" {
  run bash "$INST" issue-loop "$REPO" --profile work --repo owner/name --project-context x --review-focus y --fast-verify
  [ "$status" -eq 0 ]
  grep -q "^VERIFY_CMD=\${VERIFY_CMD:-'bash loop/verify.sh'}" "$REPO/loop/loop.conf"
  [ -x "$REPO/loop/verify.sh" ]
  rm "$REPO/loop/loop.conf"
  run bash "$INST" issue-loop "$REPO" --profile work --repo owner/name --project-context x --review-focus y --fast-verify --verify-cmd "make test"
  [ "$status" -eq 0 ]
  grep -q "^VERIFY_CMD=\${VERIFY_CMD:-'make test'}" "$REPO/loop/loop.conf"
}

# fast_verify_repo — a repo with a feature branch whose only change is a Markdown file.
fast_verify_repo() {
  git -C "$REPO" checkout -q -b feat
  printf '%s\n' "# doc" "$1" > "$REPO/doc.md"
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m doc
}

@test "verify.sh: a changed .md with a conflict marker fails, a clean one passes, and no mapfile" {
  # bash 3.2 has no mapfile/readarray (comments may mention them)
  refute grep -q 'mapfile\|readarray' <(grep -v '^ *#' "$PAT_DIR/verify.sh")
  fast_verify_repo "fine text"
  run bash -c 'cd "$1" && VERIFY_BASE=main bash "$2"' _ "$REPO" "$PAT_DIR/verify.sh"
  [ "$status" -eq 0 ]
  contains "$output" "verify: PASS"
  printf '%s\n' "<<<<<<< HEAD" "x" ">>>>>>> other" >> "$REPO/doc.md"
  run bash -c 'cd "$1" && VERIFY_BASE=main bash "$2"' _ "$REPO" "$PAT_DIR/verify.sh"
  [ "$status" -eq 1 ]
  contains "$output" "leftover merge-conflict markers"
}
