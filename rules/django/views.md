---
paths:
  - "**/views.py"
  - "**/views/*.py"
  - "**/middleware.py"
---
# Django view security

- Avoid `csrf_exempt`; it disables CSRF protection for that view.
- Read the host with `request.get_host()`; `request.META["HTTP_HOST"]` bypasses `ALLOWED_HOSTS` validation.
- Pass user values to `raw()` and `cursor.execute()` through `params` with unquoted `%s` placeholders; string formatting or quoted placeholders allow SQL injection.
- Avoid `extra()` and `RawSQL`; when unavoidable, pass user values through `params`.
- Call `mark_safe()` or the `|safe` filter only on HTML you generated or sanitised; user input is not a trusted source.
