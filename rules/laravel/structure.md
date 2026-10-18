---
paths:
  - "**/app/**/*.php"
  - "**/routes/**/*.php"
---
# Laravel application code

- Call `env()` only inside `config/*.php` and read values elsewhere with `config()`; after `php artisan config:cache` the `.env` file is not loaded, so `env()` returns only system environment variables.
- Use `with()` to eager load relations you will read; a relation read as a property loads lazily, one extra query per access.
- Use `chunkById()` instead of `chunk()` when the loop updates the column the query filters on; `chunk()` gives inconsistent results there.
