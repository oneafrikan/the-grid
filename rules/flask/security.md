---
paths:
  - "**/{app,routes}.py"
  - "**/blueprints/**/*.py"
---
# Flask request and response security

- Never call `Markup` or `|safe` on user-submitted data; autoescaping no longer protects it.
- Escape user values with `markupsafe.escape()` when you build HTML outside Jinja.
- Send uploaded files with `Content-Disposition: attachment`; uploaded HTML served inline is an XSS vector.
- Pass client file names through `werkzeug.utils.secure_filename()` before storing them; the client value can be forged.
- Validate a CSRF token on every state-changing request with the project's chosen CSRF or form extension; Flask has none built in.
- Set `Content-Security-Policy`; Jinja escaping does not stop `javascript:` URIs in `href`.
- Set the `X-Content-Type-Options: nosniff`, `X-Frame-Options: SAMEORIGIN` and `Strict-Transport-Security` response headers.
- Pass SQL values as driver parameters (`?` with `sqlite3`); string formatting makes the app open to SQL injection.
