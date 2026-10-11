---
paths:
  - "**/routers/**/*.py"
---
# FastAPI route handlers

- Declare a path operation with plain `def` when it calls a library without `await` support (most database drivers); FastAPI runs it in a threadpool.
- Set `response_model` on endpoints that return stored data; it filters out fields the output model does not declare.
- Define separate input and output models (`UserIn`, `UserOut`); one model for both returns the password to every client.
- Get database sessions from a dependency that closes them in `finally` after `yield`, and inject it with `Depends()`.
