---
paths:
  - "**/settings.py"
  - "**/settings/*.py"
---
# Django settings security

- Load `SECRET_KEY` from an environment variable or a file; a key committed to source control is no longer secret.
- Rotate keys with `SECRET_KEY_FALLBACKS` and remove the old keys in a timely manner.
- Never set `DEBUG = True` in production; it leaks source excerpts, local variables and settings.
- Set `ALLOWED_HOSTS` to explicit host names; with a wildcard, validate the `Host` header yourself.
- Set `CSRF_COOKIE_SECURE = True` and `SESSION_COOKIE_SECURE = True` once the site is served over HTTPS.
- Serve the whole site over HTTPS; protecting only login or admin pages is not enough because HTTP and HTTPS share one session cookie.
- Keep the `X-Frame-Options` middleware enabled unless third-party sites must frame your pages.
