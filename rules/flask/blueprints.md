---
paths:
  - "**/blueprints/**/*.py"
  - "**/routes.py"
---
# Flask blueprints

- Reach the app from blueprint code through `current_app` at request time; the app object does not exist at import time.
- Prefix endpoints with the blueprint name in `url_for("admin.index")`, or use `url_for(".index")` inside the same blueprint.
- Set `url_prefix` on any blueprint that has a `static_folder`; without it the app's `/static` route wins.
- Put blueprint templates in a folder named after the blueprint (`admin/index.html`) so a same-named app template cannot override them.
