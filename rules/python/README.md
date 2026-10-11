# python

Python conventions: PEP 8 and PEP 484 pitfalls, standard-library security, pytest, and FastAPI route handlers. Adapted from affaan-m/ECC's Python rules, then cut to what a cited official source supports.

## Scope

- `style.md` and `security.md` load on `**/*.py`; `.pyi` stub files are not matched (the bullets are about runtime code).
- `testing.md` loads on `test_*.py`, `*_test.py` and `conftest.py`.
- `testing.md` is written for pytest (its heading says so); `unittest` projects match the same globs.
- `fastapi.md` loads only under a `routers/` directory, the layout the FastAPI "Bigger Applications" tutorial uses. FastAPI has no distinctive file names, so this is heuristic: a FastAPI app whose handlers live elsewhere (for example `api/`) does not load it, and a non-FastAPI project with a `routers/` package does. `main.py` and `dependencies.py` are not matched, because their usual contents (CORS, app construction) are not covered by these bullets.

## Sources

| Rule file | Source |
|---|---|
| style.md | https://peps.python.org/pep-0008/ https://peps.python.org/pep-0484/ https://docs.python.org/3/tutorial/controlflow.html https://docs.python.org/3/tutorial/errors.html https://typing.python.org/en/latest/spec/protocol.html |
| security.md | https://docs.python.org/3/library/subprocess.html https://docs.python.org/3/library/pickle.html https://docs.python.org/3/library/functions.html https://docs.python.org/3/library/random.html https://docs.python.org/3/library/hmac.html https://docs.python.org/3/library/tempfile.html https://docs.python.org/3/reference/simple_stmts.html https://docs.python.org/3/library/tarfile.html |
| testing.md | https://docs.pytest.org/en/stable/how-to/monkeypatch.html https://docs.pytest.org/en/stable/how-to/tmp_path.html https://docs.pytest.org/en/stable/how-to/assert.html https://docs.pytest.org/en/stable/reference/reference.html https://docs.pytest.org/en/stable/how-to/fixtures.html https://docs.pytest.org/en/stable/how-to/mark.html |
| fastapi.md | https://fastapi.tiangolo.com/async/ https://fastapi.tiangolo.com/tutorial/bigger-applications/ https://fastapi.tiangolo.com/tutorial/response-model/ https://fastapi.tiangolo.com/tutorial/extra-models/ https://fastapi.tiangolo.com/tutorial/dependencies/dependencies-with-yield/ |

## Adaptation notes

Adapted from affaan-m/ECC (MIT), see rules/THIRD_PARTY_NOTICES.txt. Source: `rules/python/` at commit `ef648e0`. Nothing was copied verbatim; every bullet is rewritten from, and traced to, the cited sources.

| ECC file | Used for | What was kept or dropped |
|---|---|---|
| coding-style.md, patterns.md | style.md | Kept: the `Protocol` topic (as the `@runtime_checkable` pitfall) and PEP 484 typing. Dropped: the Immutability section (replaced by PEP 8/PEP 484 guidance only), the black/isort/ruff tool mandate, `dataclass` DTO examples, the context-manager and generator advice (the language already steers there), the "See skill" line. |
| security.md | security.md | Kept: the topic. Dropped: the `dotenv`/`OPENAI_API_KEY` example, the bandit mandate, the django-security pointer. Added from the standard-library documentation: `subprocess`, `pickle`, `eval`, `secrets`, `hmac`, `tempfile`, `assert`, `tarfile` items. |
| testing.md | testing.md | Kept: pytest as the framework. Dropped: the coverage command and target, the `unit`/`integration` marker example (only the registration rule from the pytest docs remains), the "See skill" line. |
| fastapi.md | fastapi.md | Kept: sync-versus-async handlers, `response_model`, no password in response models, session dependencies. Dropped: `create_app()`, thin routers, JWT claims, rate limiting, log redaction, CORS (none traced to a FastAPI source or out of path scope), the dependency-override testing bullets (they belong to test files, not route files), the "See skill" line. |
| hooks.md | none | Dropped: advice about Claude Code hooks, not Python. |
