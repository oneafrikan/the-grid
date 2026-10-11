---
paths:
  - "**/app/Models/**/*.php"
---
# Eloquent models

- List the attributes `create()`, `fill()` and `update()` may set in `$fillable`; unlisted attributes are silently discarded.
- Do not set `$guarded = []` on a model that receives request data; it makes every attribute mass assignable.
- Use `$fillable`, not `$guarded`, for JSON columns and list each nested key such as `'options->enabled'`; Laravel does not update nested JSON attributes through `$guarded`.
- Call `chaperone()` on a `hasMany()` relation when children read their parent; eager loading alone does not hydrate it, so the loop runs one query per child.
- Keep required logic out of the `saving`, `updating` and `deleting` model events; mass `update()` and `delete()` queries never fire them.
