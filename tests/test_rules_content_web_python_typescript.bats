#!/usr/bin/env bats
# Content checks for WP-066 (records R23a.qa.F1-F10, F12; F11 is closed with no change): the
# web, python and typescript bullets must say only what their cited pages say, state their
# version floors, and the READMEs must document glob limits. grep -F on repo files; the
# format is checked by `rules.py lint`.
# These are the author's own checks; independent verification is qa-engineer's.

load helpers/setup
load helpers/rules_content

setup() {
  common_setup
}

teardown() {
  common_teardown
}

@test "web/security: nonce bullet says a nonce differs per response, so static HTML uses a hash" {
  grep -qF 'must differ for every HTTP response' "$REPO_ROOT/rules/web/security.md"
  grep -qF 'use a hash for static HTML' "$REPO_ROOT/rules/web/security.md"
}

@test "web/README: no false 'no hazard stated' reason, and server-templated .html is said to match" {
  run grep -F 'no hazard stated on the cited page' "$REPO_ROOT/rules/web/README.md"
  [ "$status" -eq 1 ]
  run grep -F 'other template files are not matched' "$REPO_ROOT/rules/web/README.md"
  [ "$status" -eq 1 ]
  grep -qF 'Server-templated `.html` files' "$REPO_ROOT/rules/web/README.md"
}

@test "web/html: keyboard claim and 'every form control' are limited to what the page says" {
  run grep -F 'loses native keyboard operation' "$REPO_ROOT/rules/web/html.md"
  [ "$status" -eq 1 ]
  run grep -F 'every form control' "$REPO_ROOT/rules/web/html.md"
  [ "$status" -eq 1 ]
  grep -qF 'Give a text input or select a `<label for>`' "$REPO_ROOT/rules/web/html.md"
}

@test "web/css: animation bullet no longer says 'only' or 'every frame'" {
  run grep -F '`opacity` only' "$REPO_ROOT/rules/web/css.md"
  [ "$status" -eq 1 ]
  run grep -F 'every frame' "$REPO_ROOT/rules/web/css.md"
  [ "$status" -eq 1 ]
}

@test "web/headers: preload bullet names the includeSubDomains hazard" {
  grep -qF 'HTTPS-only' "$REPO_ROOT/rules/web/headers.md"
}

@test "python: version floors are in the bullets, and the README states the convention" {
  grep -qF 'Python 3.10' "$REPO_ROOT/rules/python/style.md"
  grep -qF 'Python 3.12' "$REPO_ROOT/rules/python/security.md"
  grep -qF 'Bullets name a minimum version where the cited page gives one.' "$REPO_ROOT/rules/python/README.md"
  # the FastAPI page that shows `str | None` as "Python 3.10+" is a source of style.md too
  grep -F '| style.md |' "$REPO_ROOT/rules/python/README.md" | grep -qF 'fastapi.tiangolo.com'
}

@test "typescript/style: external data needs a runtime check, not a type predicate" {
  grep -qF 'instanceof' "$REPO_ROOT/rules/typescript/style.md"
  run grep -F 'type predicate' "$REPO_ROOT/rules/typescript/style.md"
  [ "$status" -eq 1 ]
}

@test "typescript/tsconfig: nodenext bullet names the floating esnext target; strict is scoped to the file with compilerOptions" {
  grep -qF 'esnext' "$REPO_ROOT/rules/typescript/tsconfig.md"
  grep -qF 'floating `"target": "esnext"`' "$REPO_ROOT/rules/typescript/tsconfig.md"
  grep -qF 'holds `compilerOptions`' "$REPO_ROOT/rules/typescript/tsconfig.md"
}

@test "typescript/README: version convention and the jsconfig.json limit are documented" {
  grep -qF 'Bullets name a minimum version where the cited page gives one.' "$REPO_ROOT/rules/typescript/README.md"
  grep -qF 'jsconfig.json' "$REPO_ROOT/rules/typescript/README.md"
}

@test "typescript/tsconfig: bundler bullet does not say extensions are never required" {
  grep -qF '`bundler` resolution does not require file extensions on relative imports' "$REPO_ROOT/rules/typescript/tsconfig.md"
}

@test "web, python, typescript: every bullet is at most 240 characters" {
  [ -z "$(over_cap_bullets web python typescript)" ]
}
