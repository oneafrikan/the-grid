#!/usr/bin/env bats
# tests/helpers/setup.bash path_without: forks no `basename` per PATH entry and caches per file.
# (It took ~22-24 s per call because every executable on PATH cost a fork: R15.qa.F5.)

load helpers/setup

setup() {
  # A private PATH: mktemp, ln and cksum (the only externals path_without needs), a `basename` stub
  # that logs every fork, and three fake tools.
  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN"
  ln -s "$(command -v mktemp)" "$BIN/mktemp"
  ln -s "$(command -v ln)" "$BIN/ln"
  ln -s "$(command -v cksum)" "$BIN/cksum"
  printf '#!/bin/sh\necho x >> "%s/basename.log"\n' "$BATS_TEST_TMPDIR" > "$BIN/basename"
  printf '#!/bin/sh\n:\n' > "$BIN/jq"
  printf '#!/bin/sh\n:\n' > "$BIN/python3.12"
  printf '#!/bin/sh\n:\n' > "$BIN/keepme"
  chmod +x "$BIN/basename" "$BIN/jq" "$BIN/python3.12" "$BIN/keepme"
  : > "$BATS_TEST_TMPDIR/basename.log"
  OLDPATH="$PATH"
}

teardown() { PATH="$OLDPATH"; }

@test "path_without does not fork basename per PATH entry" {
  PATH="$BIN"
  local d
  d="$(path_without jq)"
  PATH="$OLDPATH"
  [ -e "$d/keepme" ]
  [ ! -e "$d/jq" ]
  [ ! -s "$BATS_TEST_TMPDIR/basename.log" ]
}

@test "path_without still honours glob patterns" {
  PATH="$BIN"
  local d
  d="$(path_without 'python3*')"
  PATH="$OLDPATH"
  [ -e "$d/jq" ]
  [ ! -e "$d/python3.12" ]
}

@test "path_without caches per bats file: same globs reuse the dir, different globs do not" {
  PATH="$BIN"
  local a b c
  a="$(path_without jq)"
  b="$(path_without jq)"
  c="$(path_without 'python3*')"
  PATH="$OLDPATH"
  [ "$a" = "$b" ]
  [ "$a" != "$c" ]
  # the cache lives in the per-file dir, so bats removes it
  case "$a" in "$BATS_FILE_TMPDIR"/*) ;; *) echo "cache dir $a is outside BATS_FILE_TMPDIR" >&3; false ;; esac
}

@test "path_without cache is keyed by PATH too" {
  local a b
  # a second private PATH that lacks the basename stub
  mkdir -p "$BATS_TEST_TMPDIR/bin2"
  ln -s "$BIN/keepme" "$BATS_TEST_TMPDIR/bin2/keepme"
  ln -s "$BIN/mktemp" "$BATS_TEST_TMPDIR/bin2/mktemp"
  ln -s "$BIN/ln" "$BATS_TEST_TMPDIR/bin2/ln"
  ln -s "$BIN/cksum" "$BATS_TEST_TMPDIR/bin2/cksum"
  PATH="$BIN"
  a="$(path_without jq)"
  PATH="$BATS_TEST_TMPDIR/bin2"
  b="$(path_without jq)"
  PATH="$OLDPATH"
  [ "$a" != "$b" ]
  [ ! -e "$b/basename" ]
  [ -e "$a/basename" ]
}
