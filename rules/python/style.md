---
paths:
  - "**/*.py"
---
# Python style pitfalls

- Test `if x is not None` when `0`, `""` or an empty container is a valid value; `if x` treats them as false.
- Name the exception in `except`; a bare `except:` also catches `SystemExit` and `KeyboardInterrupt`.
- Keep the `try` body to the minimum code that can raise the handled exception, so other errors are not masked.
- Chain with `raise NewError(...) from exc` when you convert an exception; without `from`, the traceback says the new error happened while handling the first, not because of it.
- Default a mutable parameter to `None` and create the list or dict in the body; a `[]` or `{}` default is evaluated once and shared across calls.
- Write `x: int | None = None` (Python 3.10 and later; use `Optional[int]` before that), not `x: int = None`; PEP 484 no longer recommends implicit `Optional`.
- Add `@runtime_checkable` to a `Protocol` before calling `isinstance()` on it; by default the check does not work with protocol types.
