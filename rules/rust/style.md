---
paths:
  - "**/*.rs"
---
# Rust style

- Name conversion methods by cost: `as_` for a free borrowed-to-borrowed view, `to_` for an expensive conversion, `into_` for a consuming owned-to-owned conversion.
- Name getters after the field (`width()`), not `get_width()`; the `get_` prefix is reserved for a single obvious thing that could be gotten.
- Take `&str` rather than `&String` as a parameter; deref coercion lets callers pass either a `String` reference or a string slice.
