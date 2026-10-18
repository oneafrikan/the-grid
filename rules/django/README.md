# django

Django conventions: settings and app layout, ORM and migrations, and the security items from Django's deployment checklist. Written fresh from the official documentation, not adapted from another rule set.

Path scope is by file name (`settings.py`, `apps.py`, `models.py`, `views.py`, and so on), one topic per file. `views.py` and `models.py` are ambiguous names that also match other frameworks; the `flask` pack deliberately leaves them to this pack.

## Scope

The globs are file-name heuristics. They are documented here, not widened, because widening adds more false loads.

- `structure.md` and `security.md` have the same `paths:` and always load together. The settings globs match any `settings.py`, including non-Django ones, and miss `settings/prod/extra.py`, `local_settings.py` and `settings_prod.py`.
- `migrations.md` loads on every `migrations/*.py`, so it also matches Alembic `migrations/env.py` and generated schema migrations, though its bullets concern `RunPython` data migrations.
- `orm.md` loads on other frameworks' `models.py` and misses `models/sub/x.py`. Its Transactions bullets concern callers in views and services, which the glob does not match.
- `views.md` misses `views/api/x.py`, `viewsets.py`, `forms.py`, `admin.py` and `templatetags/*.py`.

## Versions

Bullets are written against the Django 6.1 documentation and name a version or backend only where a bullet needs one. `orm.md` bullet 1 (`select_related()` cost) states no version: the 6.1 page also describes a per-instance fetch mode, and the bullet describes the default one-query-per-row access.

## Sources

| Rule file | Source |
|---|---|
| structure.md | https://docs.djangoproject.com/en/stable/howto/deployment/checklist/ |
| apps.md | https://docs.djangoproject.com/en/stable/ref/applications/ |
| orm.md | https://docs.djangoproject.com/en/stable/ref/models/querysets/ https://docs.djangoproject.com/en/stable/ref/models/instances/ https://docs.djangoproject.com/en/stable/ref/models/expressions/ https://docs.djangoproject.com/en/stable/topics/db/transactions/ |
| migrations.md | https://docs.djangoproject.com/en/stable/topics/migrations/ |
| security.md | https://docs.djangoproject.com/en/stable/howto/deployment/checklist/ https://docs.djangoproject.com/en/stable/topics/security/ |
| views.md | https://docs.djangoproject.com/en/stable/topics/security/ https://docs.djangoproject.com/en/stable/topics/db/sql/ https://docs.djangoproject.com/en/stable/ref/models/querysets/ |
