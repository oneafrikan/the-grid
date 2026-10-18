---
paths:
  - "**/*.rs"
---
# Rust patterns

## Errors
- Return `Result` from fallible functions instead of calling `unwrap` or `expect`; a panic cannot be recovered, so it decides for the caller. Keep `unwrap` for tests, examples, prototypes, or when you have information the compiler lacks.
- Implement `std::error::Error` for error types and make them `Send` and `Sync`; do not use `()` as an error type, because it carries nothing for callers to inspect.

## Types
- When a public trait must not be implemented outside the crate, seal it with a private supertrait (`mod private { pub trait Sealed {} }`); adding a method to an unsealed public trait is a breaking change.
