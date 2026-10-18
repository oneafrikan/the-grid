---
paths:
  - "**/app.py"
  - "**/extensions.py"
---
# Flask application factory

- Build the app inside a `create_app()` function when tests or deployments need separate instances with different settings (the `flask` command finds `create_app` or `make_app` automatically).
- Create extension objects unbound (e.g. `db = SQLAlchemy()`) and attach them in the factory with `db.init_app(app)`; `SQLAlchemy(app)` in the factory stores application state on the extension.
- Register blueprints inside the factory with `app.register_blueprint()`.
- Let the factory accept config values directly so tests need no config files on disk.
- Load configuration at the top of the factory, before any `init_app()` call, so extensions can read it.
- Register 404 and 405 handlers with `@app.errorhandler`, because invalid URLs need an app-level handler; a blueprint's handlers run only for `abort()` or `raise` inside its own views.
