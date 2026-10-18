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

# R16.qa.F11: hiding python3 must hide the whole interpreter family, or a script that falls
# back to python2.7 / pydoc3 still finds a python and the "no python" test proves nothing.
@test "path_without 'python3*' python also hides python2.7 and pydoc*, nothing else" {
  local n
  for n in python2.7 pydoc3 pydoc2.7 python; do
    printf '#!/bin/sh\n:\n' > "$BIN/$n"; chmod +x "$BIN/$n"
  done
  PATH="$BIN"
  local d
  d="$(path_without 'python3*' python)"
  PATH="$OLDPATH"
  for n in python3.12 python2.7 pydoc3 pydoc2.7 python; do
    [ ! -e "$d/$n" ] || { echo "still on PATH: $n"; false; }
  done
  [ -e "$d/jq" ]
  [ -e "$d/keepme" ]
}

@test "path_without with no python glob leaves the python family alone" {
  printf '#!/bin/sh\n:\n' > "$BIN/python2.7"; chmod +x "$BIN/python2.7"
  PATH="$BIN"
  local d
  d="$(path_without jq)"
  PATH="$OLDPATH"
  [ -e "$d/python2.7" ]
  [ -e "$d/python3.12" ]
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

# H-15 (NF-014/NF-055 VF7): the cost was one `ln` fork per executable on PATH (~4 s per call on
# a typical box, 13 s on a CI runner). Links are now made in one `ln` call per PATH dir.
# Counting forks is the deterministic check; the wall-clock test below only guards against a
# gross regression, with a wide margin.
@test "path_without forks ln once per PATH dir, not once per executable" {
  local n i d
  mkdir -p "$BATS_TEST_TMPDIR/bin2" "$BATS_TEST_TMPDIR/bin3"
  for i in $(seq 1 150); do
    printf '#!/bin/sh\n:\n' > "$BATS_TEST_TMPDIR/bin2/tool$i"
    printf '#!/bin/sh\n:\n' > "$BATS_TEST_TMPDIR/bin3/other$i"
  done
  chmod +x "$BATS_TEST_TMPDIR"/bin2/* "$BATS_TEST_TMPDIR"/bin3/*
  # an `ln` stub that logs each fork, then runs the real one
  rm "$BIN/ln"
  printf '#!/bin/sh\necho x >> "%s/ln.log"\nexec "%s" "$@"\n' "$BATS_TEST_TMPDIR" "$(command -v ln)" > "$BIN/ln"
  chmod +x "$BIN/ln"
  : > "$BATS_TEST_TMPDIR/ln.log"
  PATH="$BIN:$BATS_TEST_TMPDIR/bin2:$BATS_TEST_TMPDIR/bin3"
  d="$(path_without jq)"
  PATH="$OLDPATH"
  [ -e "$d/tool150" ]
  [ -e "$d/other150" ]
  n="$(wc -l < "$BATS_TEST_TMPDIR/ln.log")"
  # 3 PATH dirs, ~310 executables: allow a small constant on top of one call per dir.
  [ "$n" -le 6 ] || { echo "ln forked $n times for 3 PATH dirs"; false; }
}

@test "path_without: the earliest PATH entry wins on a duplicate name, and a skipped name stays skipped" {
  mkdir -p "$BATS_TEST_TMPDIR/early" "$BATS_TEST_TMPDIR/late"
  printf '#!/bin/sh\necho early\n' > "$BATS_TEST_TMPDIR/early/dup"
  printf '#!/bin/sh\necho late\n' > "$BATS_TEST_TMPDIR/late/dup"
  printf '#!/bin/sh\n:\n' > "$BATS_TEST_TMPDIR/late/dropme"
  chmod +x "$BATS_TEST_TMPDIR/early/dup" "$BATS_TEST_TMPDIR/late/dup" "$BATS_TEST_TMPDIR/late/dropme"
  PATH="$BIN:$BATS_TEST_TMPDIR/early:$BATS_TEST_TMPDIR/late"
  local d
  d="$(path_without dropme)"
  PATH="$OLDPATH"
  [ "$("$d/dup")" = early ]
  [ ! -e "$d/dropme" ]
}

@test "path_without: a 3000-executable PATH is built in well under 5 s" {
  local i start d
  mkdir -p "$BATS_TEST_TMPDIR/big"
  for i in $(seq 1 3000); do : > "$BATS_TEST_TMPDIR/big/t$i"; done
  chmod +x "$BATS_TEST_TMPDIR"/big/*
  PATH="$BIN:$BATS_TEST_TMPDIR/big"
  start=$SECONDS
  d="$(path_without jq)"
  PATH="$OLDPATH"
  [ -e "$d/t3000" ]
  [ $((SECONDS - start)) -lt 5 ] || { echo "took $((SECONDS - start)) s"; false; }
}
