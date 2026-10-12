# flask

Flask conventions: application factory, blueprints, configuration, and web security. Written fresh from the official documentation, not adapted from another rule set.

Path scope is heuristic. Flask has no distinctive file names, so the globs match common ones (`app.py`, `extensions.py`, `routes.py`, `config.py`, and files under `blueprints/`). A Flask project that uses other names will not load these rules, and a non-Flask project with an `app.py` or `config.py` will. `views.py` and `models.py` are left to the `django` pack because those names are ambiguous.

## Scope

- The globs miss `myapp/__init__.py` (where `create_app` often lives), `factory.py` and `wsgi.py`, so the `structure.md` factory bullets do not load on the commonest factory file.
- Files under `blueprints/` also load the `django` pack's `views.md` when they are named `views.py`.
- Widening the globs would add more false loads, so the limits are documented instead.

## Sources

| Rule file | Source |
|---|---|
| structure.md | https://flask.palletsprojects.com/en/stable/patterns/appfactories/ https://flask.palletsprojects.com/en/stable/config/ https://flask.palletsprojects.com/en/stable/blueprints/ |
| blueprints.md | https://flask.palletsprojects.com/en/stable/blueprints/ https://flask.palletsprojects.com/en/stable/patterns/appfactories/ |
| config.md | https://flask.palletsprojects.com/en/stable/config/ https://flask.palletsprojects.com/en/stable/web-security/ https://flask.palletsprojects.com/en/stable/quickstart/ |
| security.md | https://flask.palletsprojects.com/en/stable/web-security/ https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Strict-Transport-Security https://flask.palletsprojects.com/en/stable/quickstart/ |
