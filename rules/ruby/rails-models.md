---
paths:
  - "**/app/models/**/*.rb"
---
# Rails models

- Back `validates ..., uniqueness: true` with a unique index (`add_index ..., unique: true` in a migration); the validation alone creates no database constraint, so two connections can insert duplicates.
- Use `update` or `destroy` rather than `update_all`, `delete_all`, `update_column` or `update_columns` when callbacks must run; the latter skip callbacks, bypassing business rules and possibly leaving invalid data.
- Iterate large tables with `find_each`; `Model.all.each` fetches the entire table in one pass.
