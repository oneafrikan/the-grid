---
paths:
  - "**/app/Models/**/*.php"
---
# Eloquent models

- List the attributes `create()`, `fill()` and `update()` may set in `$fillable`; unlisted attributes are silently discarded.
- If you set `$guarded = []`, every attribute is mass assignable; always hand-craft the arrays passed to `fill`, `create` and `update`, because an unexpected request field (such as `is_admin`) is otherwise written.
- Use `$fillable`, not `$guarded`, for JSON columns and list each nested key such as `'options->enabled'`; Laravel does not update nested JSON attributes through `$guarded`.
- Where your Laravel version provides `chaperone()`, call it on a `hasMany()` relation when children read their parent; eager loading alone does not hydrate it, so the loop runs one query per child.
- Do not rely on the `saving`, `updating` and `deleting` model events when you use mass `update()` or `delete()`; those queries never fire them.
