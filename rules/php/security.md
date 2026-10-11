---
paths:
  - "**/*.php"
---
# PHP security

## Input and output
- Bind data with `PDO::prepare()` placeholders; binding covers data only, so check any dynamic table, column or `ORDER BY` name against a list of allowed values.
- Pass `ENT_QUOTES` and `'UTF-8'` to `htmlspecialchars()`; before PHP 8.1 the default `ENT_COMPAT` leaves single quotes unescaped.
- Wrap each user-supplied shell argument in `escapeshellarg()` before `exec()` or `system()`; unescaped input allows command injection.
- Pass user-supplied file names through `basename()` before building a path; `../` in the name reaches files outside the intended directory.
- Do not trust `$_FILES['file']['type']`; the client supplies it and PHP does not check it. Move the upload with `move_uploaded_file()`.
- Decode untrusted data with `json_decode()`; `unserialize()` on untrusted input is unsafe even with `allowed_classes`.

## Secrets
- Hash passwords with `password_hash($password, PASSWORD_DEFAULT)` and check them with `password_verify()`; use a column of 255 characters, since the default algorithm's output can grow.
- Generate tokens with `random_bytes()` or `random_int()`; `mt_rand()` is not cryptographically secure.
- Compare secrets and MACs with `hash_equals()`; a regular string comparison is open to timing attacks.
