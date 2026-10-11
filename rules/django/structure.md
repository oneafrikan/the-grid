---
paths:
  - "**/settings.py"
  - "**/settings/*.py"
---
# Django settings structure

- Read settings through `from django.conf import settings`; never import your own settings module or `global_settings`, because `django.conf.settings` is an object, not a module.
- Avoid reading `django.conf.settings` at module top level in reusable code; import-time access configures the settings object early and breaks `settings.configure()` users.
- Set `STATIC_ROOT` in production settings so `collectstatic` has a destination.
- Set `DEFAULT_FROM_EMAIL` and `SERVER_EMAIL` explicitly; the defaults point at `localhost` and many mail providers reject them.
