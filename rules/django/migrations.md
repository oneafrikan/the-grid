---
paths:
  - "**/migrations/*.py"
---
# Django migrations

- Write data migrations as separate migrations next to the schema migrations.
- In `RunPython`, get models with `apps.get_model()`; direct imports break when old migrations are rerun.
- Pass a reverse callable to `RunPython`; without one, migrating backwards raises an exception.
- In `dependencies`, list the latest migration of every other app whose models a `RunPython` function uses.
