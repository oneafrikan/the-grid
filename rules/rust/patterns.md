---
paths:
  - "**/*.rs"
---
# Rust patterns

## Errors
- Return `Result` from functions that can fail instead of calling `unwrap` or `expect`; a panic cannot be recovered, so it makes that decision on behalf of the calling code. Keep `unwrap` for tests, examples and prototypes.
- Implement `std::error::Error` for error types and make them `Send` and `Sync`; do not use `()` as an error type, because it carries nothing for callers to inspect.

## Types
- When a public trait must not be implemented outside the crate, seal it with a private supertrait (`mod private { pub trait Sealed {} }`); adding a method to an unsealed public trait is a breaking change.
