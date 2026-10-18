---
paths:
  - "**/*.{ts,tsx,js,jsx,mjs,cjs,mts,cts}"
---
# JavaScript and TypeScript patterns

- Iterate arrays with `for (... of ...)`; `for (... in ...)` yields the indices as strings, not the values.
- Throw `Error` instances or subclasses, never strings or plain objects; only `Error` objects record a stack trace of where they were created.
- `await` every promise or attach `.catch()`; a "floating" promise has nothing to handle its rejection, and the error is ignored.
