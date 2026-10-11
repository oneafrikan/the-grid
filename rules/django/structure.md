---
paths:
  - "**/settings.py"
  - "**/settings/*.py"
---
# Django settings structure

- Set `STATIC_ROOT` in production settings so `collectstatic` has a destination.
- Set `DEFAULT_FROM_EMAIL` and `SERVER_EMAIL` explicitly; the defaults point at `localhost` and many mail providers reject them.
