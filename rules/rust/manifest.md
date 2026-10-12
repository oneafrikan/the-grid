---
paths:
  - "**/Cargo.toml"
---
# Cargo.toml

- Set `edition` in the `[package]` table (or `edition.workspace = true` in a workspace member); when it is absent Cargo assumes the 2015 edition.
- Set `resolver` in the `[workspace]` table of a virtual manifest (one with no `[package]`); it has no `package.edition` to infer the resolver version from.
- Give dependencies a version requirement such as `"1.2.3"`, not a bare `"*"`; crates.io does not allow bare `*` versions.
