#!/usr/bin/env bash
# Portability helpers so tests run on GNU (Linux) and BSD (macOS) userland, bash 3.2 safe.
# Loaded with `load helpers/portable` by the files that need them.

# file_mode PATH -> octal permission bits (GNU stat -c, else BSD stat -f).
file_mode() { stat -c %a "$1" 2> /dev/null || stat -f %Lp "$1"; }

# sed_i SED_ARGS... FILE -> in-place edit; the .bak suffix form is accepted by both
# GNU and BSD sed, and the backup is removed so it cannot pollute directory listings.
# FILE must be the last argument.
sed_i() {
  local file="${*: -1}"
  sed -i.bak "$@" && rm -f "$file.bak"
}

# isolate_git_config -> make git ignore the operator's global/system config for this test
# (commit.gpgsign, core.hooksPath, init.templateDir, user.*). GIT_CONFIG_GLOBAL needs git
# >= 2.32 (older Apple Git ignores it), so also point HOME at an empty temp dir and drop
# XDG_CONFIG_HOME: the older git then finds no ~/.gitconfig either. Call AFTER common_setup
# (it records the real HOME as REAL_HOME first). Needs BATS_TEST_TMPDIR (bats >= 1.4).
isolate_git_config() {
  mkdir -p "$BATS_TEST_TMPDIR/githome"
  export HOME="$BATS_TEST_TMPDIR/githome"
  unset XDG_CONFIG_HOME
  export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
}
