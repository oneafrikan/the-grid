---
paths:
  - "**/tests/**/*.rs"
---
# Rust integration tests

- Put shared helpers in `tests/common/mod.rs`, not `tests/common.rs`; Cargo compiles each top-level file in `tests/` as its own test crate, so `common.rs` shows up in the output as a test run with 0 tests.
- When the package has only `src/main.rs`, move the logic into `src/lib.rs`; files in `tests/` cannot `use` items from a binary crate.
- Give each test its own files and environment variables, or run `cargo test -- --test-threads=1`; tests run in parallel by default, so shared state makes them interfere.
- Add `expected = "..."` to `#[should_panic]`; without it the test passes on a panic from any cause.
