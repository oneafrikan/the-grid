---
paths:
  - "**/models/**/*.sql"
---
# dbt models

## Layers
- Use `ref()` for models and `source()` for raw tables; a hard-coded `schema.table` hides dependencies and build order.
- Limit staging models to renaming, casting, basic computation and categorising; joins and aggregations change the grain.
- Move a CTE duplicated across models, or one that changes grain, into its own intermediate model.
- Avoid per-department copies of one concept such as `finance_orders` and `marketing_orders`; the dbt guide calls them an anti-pattern.

## Columns
- Convert timestamps to UTC in staging models, so every downstream model reads one timezone.

## Incremental
- Wrap the incremental filter in `{% if is_incremental() %}`; the model SQL must be valid either way.
- Filter with `>=` against `max()` from `{{ this }}` so rows arriving late on the last day are included.
- Set `unique_key` to update rows; without it most adapters append only.
- Keep `unique_key` columns non-null, or rows fail to match and duplicate; pass a list for composite keys.
- Omit `unique_key` for `insert_overwrite`; it replaces whole partitions.
- Set `on_schema_change` deliberately; the default `ignore` drops new columns, and no setting backfills old rows.
- Add `incremental_predicates` to a `merge` to limit how much of the target is scanned.
