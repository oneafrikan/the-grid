---
paths:
  - "**/*.php"
---
# PHP patterns

- Use `match` rather than `switch` to map a value to a result; arms compare with `===` and an unmatched value throws `UnhandledMatchError` instead of falling through.
- Pass `true` as the third argument of `in_array()`; without it the search compares loosely.
- Call `unset($value)` after `foreach ($items as &$value)`; the reference to the last element otherwise survives the loop and later writes change that element.
- Give a typed property a default or assign it in the constructor; reading an uninitialized typed property throws `Error`.
