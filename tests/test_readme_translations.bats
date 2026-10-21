#!/usr/bin/env bats
# Tests for scripts/translate-readme.sh and scripts/check-translations.sh (openspec change
# front-door, group 8). Everything runs in a throwaway copy of the scripts with a small fixture
# README; the translator is the `claude` stub from tests/helpers/stubs.bash (GRID_CLAUDE), so no
# model is ever called and nothing under the real repo or ~/.claude is written.

load helpers/setup
load helpers/stubs

# Pin the locale like the scripts do: the locale file and the bodies below hold UTF-8.
export LC_ALL=C

setup() {
  common_setup
  make_stubs
  T="$(mktemp -d)"
  mkdir -p "$T/scripts/lib" "$T/docs" "$T/agent-factory/examples"
  cp "$REPO_ROOT/scripts/translate-readme.sh" "$REPO_ROOT/scripts/check-translations.sh" \
     "$REPO_ROOT/scripts/stamp-counts.py" "$T/scripts/"
  cp "$REPO_ROOT/scripts/lib/readme-hash.sh" "$REPO_ROOT/scripts/lib/readme-locales.txt" "$T/scripts/lib/"
  cp "$REPO_ROOT/docs/translation-prompt.md" "$T/docs/"

  # Sources stamp-counts.py reads: a SKILLS.md headline and one team yaml.
  printf '**20 skills indexed** — 7 wired live (3 root-owned + 4 from allowlisted repos), 13 in library\n' > "$T/SKILLS.md"
  printf 'team:\n  - role: lead\n' > "$T/agent-factory/examples/team.yaml"

  # Fixture README: a switcher block, one count marker, two fences, relative links.
  cat > "$T/README.md" <<'EOF'
# fixture-grid

Wires <!--count:wired-->7<!--/count--> skills. See [the guide](docs/guide.md) and [LICENSE](LICENSE).

<!-- langs --><!-- /langs -->

```
BANNER
```

## Use it

I run this daily.

```bash
echo hi
```
EOF

  # A well-formed model reply: same fences, empty count marker, same relative links.
  cat > "$T/good.out" <<'EOF'
# fixture-grid (translated)

TRANSLATED <!--count:wired--><!--/count--> [the guide](docs/guide.md) [LICENSE](LICENSE)

```
BANNER
```

## Use it

TRANSLATED

```bash
echo hi
```
EOF
  # A broken reply: the last fence is missing.
  head -n 14 "$T/good.out" > "$T/bad.out"

  export STUB_CLAUDE_STDOUT="$T/good.out"
  export STUB_STDIN_DUMP="$T/stdin.dump"
  # shellcheck source=/dev/null
  . "$T/scripts/lib/readme-hash.sh"
}

teardown() {
  clean_stubs
  rm -rf "$T"
  common_teardown
}

translate() { run bash "$T/scripts/translate-readme.sh" "$@"; }
check() { run bash "$T/scripts/check-translations.sh" "$@"; }
# calls — how many times the stub was asked to translate
calls() { grep -c '^claude ' "$STUB_LOG" || true; }

@test "a generated file carries the correct header hash, notice, body and stamped counts" {
  translate --locale ja
  [ "$status" -eq 0 ]
  f="$T/README.ja.md"
  [ -f "$f" ]
  want="$(readme_source_hash "$T/README.md")"
  [ "$(head -n 1 "$f")" = "<!-- machine-translated from README.md; source-sha256=$want; locale=ja; do not edit by hand -->" ]
  [ "$(sed -n 3p "$f")" = "" ]
  [ "$(sed -n 4p "$f")" = "> Machine-translated from the [English README](README.md). The English version is authoritative." ]
  [ "$(sed -n 6p "$f")" = "# fixture-grid (translated)" ]
  # the empty marker the model returned was filled in by stamp-counts.py
  grep -qF '<!--count:wired-->7<!--/count-->' "$f"
  # the call: model flags, the empty --tools "" argument and the normalised README on stdin
  grep -qF -- '-p --model sonnet --max-budget-usd 1 --no-session-persistence --tools "" --disable-slash-commands' "$STUB_LOG"
  grep -qF '<!--count:wired--><!--/count-->' "$STUB_STDIN_DUMP"
  refute grep -qF '<!-- langs -->' "$STUB_STDIN_DUMP"
}

@test "the switcher lists only existing files, in locale-file order, current language bold" {
  translate --locale fr
  [ "$status" -eq 0 ]
  translate --locale ja
  [ "$status" -eq 0 ]
  [ "$(sed -n 2p "$T/README.ja.md")" = '<!-- langs -->[English](README.md) · **日本語** · [Français](README.fr.md)<!-- /langs -->' ]
  [ "$(sed -n 2p "$T/README.fr.md")" = '<!-- langs -->[English](README.md) · [日本語](README.ja.md) · **Français**<!-- /langs -->' ]
  grep -qF '<!-- langs -->**English** · [日本語](README.ja.md) · [Français](README.fr.md)<!-- /langs -->' "$T/README.md"
  refute grep -qF 'README.de.md' "$T/README.md"
}

@test "editing README prose makes check-translations print STALE and exit 1" {
  translate --locale ja
  [ "$status" -eq 0 ]
  check
  [ "$status" -eq 0 ]
  printf '\nA new sentence of prose.\n' >> "$T/README.md"
  check
  [ "$status" -eq 1 ]
  [[ "$output" == *"STALE ja"* ]] || false
}

@test "changing only a count marker value or the switcher block does not make a translation stale" {
  translate --locale ja
  [ "$status" -eq 0 ]
  sed -e 's/<!--count:wired-->7/<!--count:wired-->99/' \
      -e 's#<!-- langs -->.*<!-- /langs -->#<!-- langs -->something else<!-- /langs -->#' \
      "$T/README.md" > "$T/README.new"
  mv "$T/README.new" "$T/README.md"
  check
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "broken model output (fence mismatch) leaves the old file untouched and exits 1" {
  translate --locale ja
  [ "$status" -eq 0 ]
  cp "$T/README.ja.md" "$T/ja.before"
  # make ja stale so a regeneration is attempted, then answer with the broken body
  printf '\nA new sentence of prose.\n' >> "$T/README.md"
  export STUB_CLAUDE_STDOUT="$T/bad.out"
  translate --locale ja
  [ "$status" -eq 1 ]
  [[ "$output" == *"fence"* ]] || false
  cmp "$T/README.ja.md" "$T/ja.before"
  # a locale with no file yet stays absent
  translate --locale fr
  [ "$status" -eq 1 ]
  [ ! -e "$T/README.fr.md" ]
}

@test "--strict fails on a missing locale; without it a repo with no translations passes" {
  check
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  check --strict
  [ "$status" -eq 1 ]
  [[ "$output" == *"MISSING ja"* ]] || false
}

@test "--dry-run never invokes the stub and writes nothing" {
  translate --all --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"translate ja"* ]] || false
  [[ "$output" == *"estimated input per locale:"* ]] || false
  [ "$(calls)" -eq 0 ]
  [ ! -e "$T/README.ja.md" ]
}

@test "--switcher-only makes no stub call and rewrites every switcher" {
  translate --locale ja
  [ "$status" -eq 0 ]
  translate --locale fr
  [ "$status" -eq 0 ]
  before="$(calls)"
  # drop one translation: the other files must stop listing it
  rm "$T/README.fr.md"
  translate --switcher-only
  [ "$status" -eq 0 ]
  [ "$(calls)" -eq "$before" ]
  refute grep -qF 'README.fr.md' "$T/README.md"
  refute grep -qF 'README.fr.md' "$T/README.ja.md"
  [ "$(sed -n 2p "$T/README.ja.md")" = '<!-- langs -->[English](README.md) · **日本語**<!-- /langs -->' ]
}

@test "a second --all run with an unchanged README calls nothing and changes no byte" {
  translate --all
  [ "$status" -eq 0 ]
  [ "$(calls)" -eq 9 ]
  cksum "$T"/README*.md > "$T/sums.before"
  translate --all
  [ "$status" -eq 0 ]
  [ "$(calls)" -eq 9 ]
  cksum "$T"/README*.md > "$T/sums.after"
  cmp "$T/sums.before" "$T/sums.after"
}
