---
paths:
  - "**/{test_*,*_test,conftest}.py"
---
# pytest conventions

## When the project uses pytest
- Change environment variables and attributes with the `monkeypatch` fixture (`setenv`, `setattr`); it undoes every change after the test.
- Write files under the `tmp_path` fixture; it is a temporary directory unique to each test.
- Pass `match=` to `pytest.raises()` to check the exception message as well as its type.
- Avoid `pytest.raises(Exception)`; it hides real bugs when a different exception is raised after a refactor.
- Compare floats with `pytest.approx()`; `0.1 + 0.2 == 0.3` is `False`.
- Split setup steps that each need cleanup into separate `yield` fixtures; if setup raises before `yield`, that fixture's teardown does not run.
- Register custom marks in the pytest configuration `markers` option and set `--strict-markers`; unregistered marks only warn.
