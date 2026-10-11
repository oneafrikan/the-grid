---
paths:
  - "**/*.{test,spec}.{ts,tsx,js,jsx,mjs,cjs,mts,cts}"
---
# Async tests

## When tests run on Jest
- When you assert a rejection with `.catch()`, call `expect.assertions(n)`; otherwise a fulfilled promise passes the test.
