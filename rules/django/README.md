# django

Django conventions: settings and app layout, ORM and migrations, and the security items from Django's deployment checklist. Written fresh from the official documentation, not adapted from another rule set.

Path scope is by file name (`settings.py`, `apps.py`, `models.py`, `views.py`, and so on), one topic per file. `views.py` and `models.py` are ambiguous names that also match other frameworks; the `flask` pack deliberately leaves them to this pack.

## Sources

| Rule file | Source |
|---|---|
| structure.md | https://docs.djangoproject.com/en/stable/topics/settings/ https://docs.djangoproject.com/en/stable/howto/deployment/checklist/ https://docs.djangoproject.com/en/stable/internals/contributing/writing-code/coding-style/ |
| apps.md | https://docs.djangoproject.com/en/stable/ref/applications/ |
| orm.md | https://docs.djangoproject.com/en/stable/ref/models/querysets/ https://docs.djangoproject.com/en/stable/ref/models/instances/ https://docs.djangoproject.com/en/stable/ref/models/expressions/ https://docs.djangoproject.com/en/stable/topics/db/transactions/ |
| migrations.md | https://docs.djangoproject.com/en/stable/topics/migrations/ |
| security.md | https://docs.djangoproject.com/en/stable/howto/deployment/checklist/ https://docs.djangoproject.com/en/stable/topics/security/ |
| views.md | https://docs.djangoproject.com/en/stable/topics/security/ https://docs.djangoproject.com/en/stable/topics/db/sql/ https://docs.djangoproject.com/en/stable/ref/models/querysets/ |
