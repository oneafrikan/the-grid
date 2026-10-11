---
paths:
  - "**/{models,managers}.py"
  - "**/models/*.py"
---
# Django ORM

## Queries
- Use `select_related()` for ForeignKey and OneToOne relations read per row; unprefetched related access costs one query per row.
- Use `prefetch_related()` for many-to-many and many-to-one relations (separate lookup, joined in Python); pass `Prefetch(..., queryset=...)` to filter or order the related rows.
- Use `exists()` to test for rows and `count()` for a number when the objects are not needed; use `len()` only when you iterate the queryset anyway.
- Use `F("field")` for in-database arithmetic (`update(n=F("n") + 1)`); a read-modify-write in Python is a race condition.
- After `QuerySet.update()` with `F()`, call `refresh_from_db()` before reading the instance, which still holds the old value.
- Pass `update_fields=[...]` to `save()` to write only those columns; fields left out skip `pre_save()`, so `auto_now` is not refreshed.
- Avoid `update()`, `bulk_create()` and `bulk_update()` when logic lives in `save()` or signals; they call neither.
- Call `full_clean()` before `save()` for data that bypasses forms; `save()` never validates.

## Transactions
- Catch database errors around a `transaction.atomic()` block, never inside it; a swallowed error breaks the transaction and later queries raise `TransactionManagementError`.
- Use `transaction.on_commit()` for side effects such as emails; its callback is discarded when the transaction rolls back.
- Call `select_for_update()` only inside `transaction.atomic()`; in autocommit mode it raises `TransactionManagementError`.
