#!/usr/bin/env bats
# Content checks for WP-068 (records R23b.qa.F1-F8, F13, F14): php, laravel and wordpress
# bullets must not turn documented options into bans or mandates, and the READMEs must
# document the glob overlaps the glob grammar cannot fix. grep -F on repo files; the format
# is checked by `rules.py lint`.
# These are the author's own checks; independent verification is qa-engineer's.

load helpers/setup
load helpers/rules_content

setup() {
  common_setup
}

teardown() {
  common_teardown
}

@test "php/patterns: match is described with its PHP 8.0 floor, not preferred over switch" {
  grep -qF 'On PHP 8.0 and later' "$REPO_ROOT/rules/php/patterns.md"
  run grep -F 'Use `match` rather than' "$REPO_ROOT/rules/php/patterns.md"
  [ "$status" -eq 1 ]
}

@test "wordpress/structure: prefix is at least 4 letters (5 recommended), not 4 to 5" {
  grep -qF 'at least 4 letters' "$REPO_ROOT/rules/wordpress/structure.md"
  run grep -F '4 to 5 letters' "$REPO_ROOT/rules/wordpress/structure.md"
  [ "$status" -eq 1 ]
}

@test "wordpress/structure: plugin-only advice says so (function_exists, plugins_url)" {
  [ -n "$(bullet_line rules/wordpress/structure.md 'In a plugin, reserve')" ]
  grep -qF 'in a plugin build the URL with `plugins_url()`' "$REPO_ROOT/rules/wordpress/structure.md"
}

@test "wordpress/structure: argument swapping is for more than one placeholder" {
  grep -qF 'more than one placeholder' "$REPO_ROOT/rules/wordpress/structure.md"
}

@test "laravel/queues: deleteWhenMissingModels is described with its silent-discard hazard, not mandated" {
  grep -qF 'quietly discard' "$REPO_ROOT/rules/laravel/queues.md"
  run grep -F 'Set `public $deleteWhenMissingModels' "$REPO_ROOT/rules/laravel/queues.md"
  [ "$status" -eq 1 ]
}

@test "laravel/eloquent: guarded and model-event bullets state the sourced hazard, not a ban" {
  grep -qF 'hand-craft' "$REPO_ROOT/rules/laravel/eloquent.md"
  grep -qF 'Do not rely on the `saving`' "$REPO_ROOT/rules/laravel/eloquent.md"
  run grep -F 'Do not set `$guarded = []`' "$REPO_ROOT/rules/laravel/eloquent.md"
  [ "$status" -eq 1 ]
}

@test "READMEs document the glob overlaps: vendored code, php vs wordpress precedence, non-Laravel app/ trees" {
  grep -qF 'vendored third-party code' "$REPO_ROOT/rules/php/README.md"
  grep -qF 'vendored third-party code' "$REPO_ROOT/rules/wordpress/README.md"
  grep -qF 'take precedence over the PDO and `htmlspecialchars()` bullets' "$REPO_ROOT/rules/php/README.md"
  grep -qF 'CodeIgniter' "$REPO_ROOT/rules/laravel/README.md"
}

@test "wordpress/structure: prefix list omits constants on purpose, and the README says so" {
  run grep -F 'constant' "$REPO_ROOT/rules/wordpress/structure.md"
  [ "$status" -eq 1 ]
  grep -qF 'leaves out constants' "$REPO_ROOT/rules/wordpress/README.md"
}

@test "wordpress/structure: enqueue bullet names the hooks and forbids hardcoded script tags" {
  grep -qF 'with `wp_enqueue_script()`, not hardcoded `<script>` tags' "$REPO_ROOT/rules/wordpress/structure.md"
  grep -qF '`wp_enqueue_scripts`, `admin_enqueue_scripts` or `login_enqueue_scripts`' "$REPO_ROOT/rules/wordpress/structure.md"
}

@test "wordpress/security: %i placeholder states the WordPress version that added it" {
  grep -qF '`%i` (identifiers, added in WordPress 6.2.0)' "$REPO_ROOT/rules/wordpress/security.md"
}

@test "laravel: change() and chaperone() bullets carry a Laravel-version qualifier" {
  grep -qF 'depending on your Laravel version' "$REPO_ROOT/rules/laravel/migrations.md"
  grep -qF 'Where your Laravel version provides `chaperone()`' "$REPO_ROOT/rules/laravel/eloquent.md"
}

@test "php, laravel, wordpress: every bullet is at most 240 characters" {
  [ -z "$(over_cap_bullets php laravel wordpress)" ]
}
