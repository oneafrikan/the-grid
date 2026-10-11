# rust

Rust conventions: API Guidelines naming and types, `Result` over panics, `unsafe` hygiene, integer pitfalls, integration-test layout and `Cargo.toml` fields. Adapted from affaan-m/ECC's Rust rules, then cut to what a cited official source supports.

## Scope

- `style.md`, `patterns.md` and `security.md` load on `**/*.rs`; every bullet applies to any Rust source file.
- `testing.md` loads on files under a `tests/` directory only (Cargo's integration-test location). Unit tests inside `src/` are not matched, because their `#[cfg(test)]` modules live in ordinary source files that these globs cannot tell apart. `benches/` is not covered.
- `manifest.md` loads on `Cargo.toml` only. `Cargo.lock` is not matched.
- The `sqlx` bullet in `security.md` is conditional on the project using that crate; other database crates are not covered.
- Async, concurrency and web-framework rules are not covered.

## Sources

| Rule file | Source |
|---|---|
| style.md | https://rust-lang.github.io/api-guidelines/naming.html https://doc.rust-lang.org/book/ch04-03-slices.html |
| patterns.md | https://doc.rust-lang.org/book/ch09-03-to-panic-or-not-to-panic.html https://rust-lang.github.io/api-guidelines/interoperability.html https://rust-lang.github.io/api-guidelines/future-proofing.html |
| security.md | https://std-dev-guide.rust-lang.org/policy/safety-comments.html https://doc.rust-lang.org/book/ch20-01-unsafe-rust.html https://doc.rust-lang.org/book/ch03-02-data-types.html https://doc.rust-lang.org/reference/expressions/operator-expr.html https://doc.rust-lang.org/std/convert/trait.TryFrom.html https://docs.rs/sqlx/latest/sqlx/fn.query.html |
| testing.md | https://doc.rust-lang.org/book/ch11-01-writing-tests.html https://doc.rust-lang.org/book/ch11-02-running-tests.html https://doc.rust-lang.org/book/ch11-03-test-organization.html |
| manifest.md | https://doc.rust-lang.org/cargo/reference/manifest.html https://doc.rust-lang.org/cargo/reference/workspaces.html https://doc.rust-lang.org/cargo/reference/specifying-dependencies.html |

## Adaptation notes

Adapted from affaan-m/ECC (MIT), see rules/THIRD_PARTY_NOTICES.txt. Source: `rules/rust/` at commit `ef648e0`. ECC's four rule files total about 16 KB; this pack is under 5 KB. Nothing was copied verbatim; every bullet is rewritten from, and traced to, the cited sources.

| ECC file | Used for | What was kept or dropped |
|---|---|---|
| coding-style.md | style.md, patterns.md | Kept: naming and `&str` parameters (from the API Guidelines and the Rust book), `Result` over `unwrap`. Dropped: the `rustfmt` and `cargo clippy -- -D warnings` mandates, the Immutability section and `Cow` example, the `thiserror`/`anyhow` mandate (no cited source requires either), iterator-over-loop preference, domain-based module layout, `pub(crate)` visibility advice, indentation and line-width numbers (rustfmt defaults), the "See skill" pointer. |
| patterns.md | patterns.md | Kept: the sealed-trait topic (rewritten from the API Guidelines). Dropped: the newtype and private-fields guidance (optional design patterns, not hazards), repository pattern, service layer, builder, API response envelope (application designs, not language conventions), the enum state machine and "no wildcard `_`" rule (no cited source). |
| security.md | security.md | Kept: `unsafe` hygiene (`// SAFETY:` comments), parameterized SQL (conditional on `sqlx`). Dropped: `cargo audit` (a scan step, not a code convention), the hardcoded-secret example, environment-variable and `.gitignore` advice, the "parse, don't validate" and email example, the "never use `unsafe` to bypass the borrow checker" and "audit during review" lines, `cargo deny`, `cargo tree`, Dependabot/Renovate and minimise-dependencies advice, the error-message and `tracing` section (axum example, no cited source). Added from the sources: integer overflow, `as` truncation, `# Safety` sections. |
| testing.md | testing.md | Kept: the `tests/` integration-test topic (re-derived from chapter 11 of the Rust book). Dropped: `rstest`, `proptest`, `mockall` and `#[tokio::test]` (no cited source names them as required), the test-naming advice, the 80% coverage target and `cargo-llvm-cov`, the command list, the unit-test example, the "See skill" pointer. |
| hooks.md | none | Dropped: advice about Claude Code hooks, not Rust. |

`manifest.md` is new, from the Cargo documentation; ECC has no `Cargo.toml` rules. The `cargo clippy` lint set is not covered.
