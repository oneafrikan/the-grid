---
paths:
  - "**/*.sql"
---
# SQL style

- Aggregate on the smallest data set possible before joining to another table.
- Use `union all` unless you want duplicates removed; `union` silently drops duplicate rows.
