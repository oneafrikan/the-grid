---
paths:
  - "**/app/Http/**/*.php"
  - "**/routes/**/*.php"
---
# Laravel requests and authorization

- Return `true` from `authorize()` in a Form Request when authorization lives elsewhere; a request whose `authorize()` returns `false` gets a 403 and never reaches the controller.
- Read input with `$request->validated()` or `$request->safe()->only([...])`; keys no rule covers are left out.
- Pass user values to `whereRaw()` and `selectRaw()` as the bindings array; raw strings are inserted into the SQL as written.
- Exclude a URI from CSRF protection only for a caller that cannot send a token, such as a payment webhook; the exclusion disables the check for that route.
