---
paths:
  - "**/*.sql"
---
# SQL style

- In the dbt Labs style guide, aggregations are executed as early as possible, before joining another table, to improve performance.
- Use `union all` unless you want duplicates removed; `union` silently drops duplicate rows.
