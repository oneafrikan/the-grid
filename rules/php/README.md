# php

PHP language pitfalls and security functions. Framework rules live in the `laravel` and `wordpress` packs, which also load on PHP files. `composer.json` and `composer.lock` are not matched by any rule file here.

Adapted from affaan-m/ECC (MIT), see rules/THIRD_PARTY_NOTICES.txt

## Sources

| Rule file | Source |
|---|---|
| patterns.md | https://www.php.net/manual/en/control-structures.match.php https://www.php.net/manual/en/function.in-array.php https://www.php.net/manual/en/control-structures.foreach.php https://www.php.net/manual/en/language.oop5.properties.php |
| security.md | https://www.php.net/manual/en/security.database.sql-injection.php https://www.php.net/manual/en/function.htmlspecialchars.php https://www.php.net/manual/en/function.escapeshellarg.php https://www.php.net/manual/en/security.filesystem.php https://www.php.net/manual/en/features.file-upload.post-method.php https://www.php.net/manual/en/function.unserialize.php https://www.php.net/manual/en/function.password-hash.php https://www.php.net/manual/en/function.random-bytes.php https://www.php.net/manual/en/function.mt-rand.php https://www.php.net/manual/en/function.hash-equals.php |

## Adaptation notes

Adapted from affaan-m/ECC (MIT), see rules/THIRD_PARTY_NOTICES.txt. Source: `rules/php/{coding-style,patterns,security,testing}.md` at the pinned commit. Kept as the topic list: language pitfalls, security basics (prepared statements, output escaping, `password_hash()`). Every bullet was rewritten against the sources above, and each ECC bullet that no cited page supports was dropped.

- Dropped: `hooks.md`, the Immutability section, the coverage section and flags, all "See skill" lines and `extends common/` lines.
- Dropped as taste or unsourced: PSR-12 as a blanket instruction, PHP-CS-Fixer, Pint, PHPStan and Psalm named as required tools, Composer scripts in CI, DTO and value object advice, constructor injection and adapter layering, the Pest-versus-PHPUnit preference, `assertInertia`, `composer audit` and dependency pinning, CSRF and session regeneration (no cited page states them as such; framework packs cover CSRF).
- Dropped as framework-specific: Laravel `FormRequest` validation and mass assignment, which belong to the `laravel` pack.
- Dropped after review: `style.md` (strict types and PSR-12 closing-tag bullets were judged project-wide taste), `testing.md` (its globs also match Pest test files, so its PHPUnit-only bullets were judged too wide), `readonly` properties, the `JSON_THROW_ON_ERROR` bullet (the cited page does not state its behaviour) and the `Throwable` bullet (the cited page does not state that `Exception` misses `Error`).
- Scope: every rule file loads on every `.php` file.
