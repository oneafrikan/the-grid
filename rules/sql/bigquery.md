---
paths:
  - "**/*.sql"
---
# BigQuery

## Cost
- In BigQuery, name the columns you need; `SELECT *` reads every column.
- In BigQuery, filter on the partitioning column in `WHERE` so partitions are pruned.
- In BigQuery, compare the partitioning column to constants; a subquery, an `OR`, or a comparison to another column disables pruning.
- On large partitioned BigQuery tables, set `require_partition_filter = true` with `ALTER TABLE ... SET OPTIONS` so unfiltered queries fail.
- In BigQuery, estimate bytes with a dry run, which also shows whether pruning applies.
- In BigQuery, set maximum bytes billed on on-demand queries so a bad scan fails instead of billing.
- In BigQuery, never use `LIMIT` to control cost on a non-clustered table; it does not cut bytes scanned.
- In BigQuery, use a time-partitioned table instead of date-named shards (`events_20240101`); each shard keeps its own schema and metadata.

## Query shape
- In BigQuery, list the largest table first in a `JOIN`, then the smallest.
- In BigQuery, join on `INT64` keys rather than `STRING` keys; they compare faster.
- In BigQuery, replace a self-join with a window function or `PIVOT`.
- In BigQuery, avoid joins that produce more rows than they read, such as a `CROSS JOIN`.
- In BigQuery, write results used more than once to a temporary table; a repeatedly referenced CTE may be evaluated each time.
- In BigQuery, keep `ORDER BY` in the outermost query or a window function, not mid-query.
