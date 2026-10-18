---
paths:
  - "**/apps.py"
---
# Django app configuration

- Define the `AppConfig` subclass in `apps.py`; Django finds it when `INSTALLED_APPS` lists the app package.
- Import models inside `AppConfig.ready()` or with `self.get_model()`; models cannot be imported at module level where `AppConfig` classes are defined.
- Avoid database access in `ready()`; it runs during startup of every management command, so even `manage.py test` would query the production database.
- Set `default_auto_field` on the `AppConfig` of a reusable app that defines models, so its migrations match its models.
- Keep `AppConfig.label` unique across the project; changing it after migrations are applied breaks existing installs.
