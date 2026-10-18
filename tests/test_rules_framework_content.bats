#!/usr/bin/env bats
# Content checks for the django, flask, ruby, golang and rust packs (WP-064, records
# R22b.qa.F1/F2/F3/F7/F8/F9): bullets must say what their cited pages say, and each
# framework README must state what its globs load on and miss. grep -F on repo files; the
# format itself is checked by `rules.py lint`.
# These are the author's own checks; independent verification is qa-engineer's.

load helpers/setup
load helpers/rules_content

setup() {
  common_setup
}

teardown() {
  common_teardown
}

@test "django/views: RawSQL is the documented replacement for extra(), not something to avoid" {
  run grep -F 'Avoid `extra()` and `RawSQL`' "$REPO_ROOT/rules/django/views.md"
  [ "$status" -eq 1 ]
  grep -qF 'use `RawSQL`' "$REPO_ROOT/rules/django/views.md"
}

@test "flask/blueprints: an app template at the same path still overrides a blueprint template" {
  run grep -F 'cannot override' "$REPO_ROOT/rules/flask/blueprints.md"
  [ "$status" -eq 1 ]
  grep -qF 'still overrides' "$REPO_ROOT/rules/flask/blueprints.md"
}

@test "flask/security: the headers bullet says review, and limits HSTS to a fully HTTPS site" {
  run grep -F -- '- Set the `X-Content-Type-Options' "$REPO_ROOT/rules/flask/security.md"
  [ "$status" -eq 1 ]
  grep -qF 'HSTS only when the whole site is served over HTTPS' "$REPO_ROOT/rules/flask/security.md"
}

@test "flask/structure: factory and 404/405 bullets carry their conditions" {
  grep -qF 'when tests or deployments need separate instances' "$REPO_ROOT/rules/flask/structure.md"
  grep -qF 'invalid URLs need an app-level handler' "$REPO_ROOT/rules/flask/structure.md"
}

@test "flask: blueprint static bullet allows static_url_path, CSRF bullet is conditional on cookie auth" {
  grep -qF '`static_url_path`' "$REPO_ROOT/rules/flask/blueprints.md"
  grep -qF 'If authentication information is stored in cookies' "$REPO_ROOT/rules/flask/security.md"
}

@test "django: version, backend and condition qualifiers from the cited pages" {
  grep -qF 'on a backend that supports `SELECT ... FOR UPDATE`' "$REPO_ROOT/rules/django/orm.md"
  grep -qF 'will not be evaluated anyway' "$REPO_ROOT/rules/django/orm.md"
  grep -qF 'extra `atomic()` block' "$REPO_ROOT/rules/django/orm.md"
  grep -qF 'If the site sends email,' "$REPO_ROOT/rules/django/structure.md"
  grep -qF 'every management command' "$REPO_ROOT/rules/django/apps.md"
}

@test "ruby, golang, rust: bullets carry the conditions their sources give" {
  grep -qF 'In rspec-rails,' "$REPO_ROOT/rules/ruby/rspec.md"
  grep -qF 'Prefer `errors.Is` and `errors.As`' "$REPO_ROOT/rules/golang/style.md"
  grep -qF 'backwards compatibility' "$REPO_ROOT/rules/golang/patterns.md"
  run grep -F 'for mocking' "$REPO_ROOT/rules/golang/patterns.md"
  [ "$status" -eq 1 ]
  grep -qF 'information the compiler lacks' "$REPO_ROOT/rules/rust/patterns.md" \
    || grep -qF 'more than the compiler' "$REPO_ROOT/rules/rust/patterns.md"
  grep -qF 'standard library developers guide' "$REPO_ROOT/rules/rust/security.md"
  grep -qF 'wrap silently by default' "$REPO_ROOT/rules/rust/security.md"
  grep -qF 'edition.workspace = true' "$REPO_ROOT/rules/rust/manifest.md"
}

@test "framework READMEs have a Scope section naming the files their globs miss" {
  grep -qF '## Scope' "$REPO_ROOT/rules/django/README.md"
  grep -qF 'local_settings.py' "$REPO_ROOT/rules/django/README.md"
  grep -qF '## Scope' "$REPO_ROOT/rules/flask/README.md"
  grep -qF 'factory.py' "$REPO_ROOT/rules/flask/README.md"
  grep -qF '.haml' "$REPO_ROOT/rules/ruby/README.md"
  grep -qF 'go.work' "$REPO_ROOT/rules/golang/README.md"
  grep -qF '## Versions' "$REPO_ROOT/rules/django/README.md"
}

@test "django, flask, ruby, golang, rust: every bullet is at most 240 characters" {
  [ -z "$(over_cap_bullets django flask ruby golang rust)" ]
}
