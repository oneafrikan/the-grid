---
paths:
  - "**/*.rs"
---
# Rust security

## unsafe
- Precede each `unsafe` block with a `// SAFETY:` comment saying why the operation is sound and which invariants it relies on.
- Document each `unsafe fn` with a `# Safety` doc section listing what callers must uphold.
- Keep `unsafe` blocks small and wrap them in a safe API; `unsafe` does not disable the borrow checker, it only unlocks five unchecked operations.

## Numbers
- Use `checked_add`, `saturating_add` or `wrapping_add` where overflow is possible; release builds wrap silently instead of panicking, so a bug caught in debug passes unnoticed.
- Convert integers with `u8::try_from(x)` when the value may not fit; `x as u8` truncates silently.

## Database
- When the project uses `sqlx`, pass values with `.bind()` and `$1` (Postgres) or `?` (MySQL) placeholders; interpolating them with `format!` is an SQL injection.
