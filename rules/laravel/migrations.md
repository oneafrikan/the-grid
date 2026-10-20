---
paths:
  - "**/database/migrations/**/*.php"
---
# Laravel migrations

- Repeat every modifier you want to keep (`nullable()`, `default()`, `unsigned()`, `comment()`) when calling `change()` on a column; depending on your Laravel version, omitted attributes may be dropped.
- Add or drop an index modifier explicitly alongside `change()`; `change()` does not touch the column's indexes.
