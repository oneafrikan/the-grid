# flask

Flask conventions: application factory, blueprints, configuration, and web security. Written fresh from the official documentation, not adapted from another rule set.

Path scope is heuristic. Flask has no distinctive file names, so the globs match common ones (`app.py`, `extensions.py`, `routes.py`, `config.py`, and files under `blueprints/`). A Flask project that uses other names will not load these rules, and a non-Flask project with an `app.py` or `config.py` will. `views.py` and `models.py` are left to the `django` pack because those names are ambiguous.

## Sources

| Rule file | Source |
|---|---|
| structure.md | https://flask.palletsprojects.com/en/stable/patterns/appfactories/ https://flask.palletsprojects.com/en/stable/config/ https://flask.palletsprojects.com/en/stable/blueprints/ |
| blueprints.md | https://flask.palletsprojects.com/en/stable/blueprints/ https://flask.palletsprojects.com/en/stable/patterns/appfactories/ |
| config.md | https://flask.palletsprojects.com/en/stable/config/ https://flask.palletsprojects.com/en/stable/web-security/ https://flask.palletsprojects.com/en/stable/quickstart/ |
| security.md | https://flask.palletsprojects.com/en/stable/web-security/ https://flask.palletsprojects.com/en/stable/quickstart/ https://flask.palletsprojects.com/en/stable/patterns/sqlite3/ |
