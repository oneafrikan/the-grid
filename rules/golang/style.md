---
paths:
  - "**/*.go"
---
# Go style

- Wrap an error with `%w` in `fmt.Errorf` only when callers should match it with `errors.Is` or `errors.As`; wrapping makes the inner error part of your API, so use `%v` to hide implementation details.
- Prefer `errors.Is` and `errors.As` to `==` or a type assertion; they examine the whole wrapped chain.
- Start error strings lowercase and omit trailing punctuation; they are usually printed following other context.
