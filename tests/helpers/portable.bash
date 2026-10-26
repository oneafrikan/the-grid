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
