---
paths:
  - "**/blueprints/**/*.py"
  - "**/routes.py"
---
# Flask blueprints

- With the application factory pattern, reach the app from blueprint code through `current_app` at request time; the app object does not exist at import time.
- Prefix endpoints with the blueprint name in `url_for("admin.index")`, or use `url_for(".index")` inside the same blueprint.
- Set `url_prefix` or `static_url_path` on any blueprint that has a `static_folder`; with neither, a folder named `static` is served at `/static`, where the app's route wins.
- Put blueprint templates in a folder named after the blueprint (`admin/index.html`) to avoid accidental clashes with app templates; an application template at the same path still overrides it by design.
