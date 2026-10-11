---
paths:
  - "**/*.py"
---
# Python standard-library security

- Pass `subprocess` arguments as a list; with `shell=True` you must quote every metacharacter yourself (`shlex.quote()`) or risk shell injection.
- Never call `pickle.loads()` or `pickle.load()` on data from an untrusted source; unpickling can execute arbitrary code. Use `json` for untrusted data.
- Never call `eval()` or `exec()` on untrusted input; they execute arbitrary code. Use `ast.literal_eval()` for strings that contain only literals.
- Generate tokens and keys with `secrets`, not `random`; the `random` generators are unsuitable for security purposes.
- Compare secrets, signatures and digests with `hmac.compare_digest()`; it avoids content-based short circuiting that enables timing analysis.
- Create temporary files with `NamedTemporaryFile()`; `tempfile.mktemp()` returns a name another process can claim first.
- Raise an exception to validate input or enforce access; `assert` emits no code under `python -O`.
- Pass `filter="data"` to `TarFile.extractall()`; before Python 3.14 the default filter does not block unsafe archive members, and `data` still does not block everything.
