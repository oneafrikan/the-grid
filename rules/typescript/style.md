---
paths:
  - "**/*.{ts,tsx,mts,cts}"
---
# TypeScript types

- Type values of unknown shape as `unknown`, not `any`; `any` disables type checking, and `unknown` forces you to narrow first.
- Narrow a `catch` variable with `instanceof Error` before reading `.message`; under `strict` it is `unknown` (`useUnknownInCatchVariables`).
- Check external data (parsed JSON, request bodies) with an explicit runtime check (for example `instanceof`), not `as T`; type assertions are removed at compile time, so there is no runtime checking.
