---
paths:
  - "**/*.sql"
---
# SQL safety

## Injection
- Do not pass table or column names as query parameters (`@table`); parameters cannot substitute identifiers.
- In BigQuery, use positional (`?`) or named (`@name`) parameters in one query, not both.

## DML
- In BigQuery, use `TRUNCATE TABLE` to remove all rows; it keeps table metadata and is not billed.
- In BigQuery, make the `MERGE` source unique on the join key; several source rows matching one target row raises an error.
- In BigQuery, batch rows into one `INSERT` or `MERGE`; single-row DML statements hit per-table DML limits.
