---
paths:
  - "**/config.py"
---
# Flask configuration and secrets

## Loading
- Keep a default config in version control and override it per deployment with `app.config.from_envvar()` or `app.config.from_prefixed_env()` (`FLASK_` prefix).
- Use uppercase keys in config files; only uppercase values are stored in `app.config`.
- Put deployment-specific config files in the instance folder (`instance_relative_config=True`), outside version control.

## Security
- Set `SECRET_KEY` to a long random value from `secrets.token_hex()`, loaded from config outside version control; a key committed to source control is no longer secret.
- Rotate keys with `SECRET_KEY_FALLBACKS` (Flask 3.1+) and remove the old keys after a while.
- Never enable debug mode in production; the interactive debugger allows arbitrary code execution. Start it with `flask run --debug`, not `DEBUG` in code, which is read too late.
- Set `SESSION_COOKIE_SECURE = True` when the app is served over HTTPS; the default is `False`.
- Set `SESSION_COOKIE_SAMESITE = "Lax"`; the default is `None`, and `Lax` withholds the cookie on CSRF-prone cross-site requests.
- Keep `SESSION_COOKIE_HTTPONLY` at its default `True` so JavaScript cannot read the session cookie.
- Set `TRUSTED_HOSTS` in production (Flask 3.1+); the default accepts any `Host` header.
- Set `MAX_CONTENT_LENGTH`; it is unset by default.
