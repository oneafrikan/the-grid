---
paths:
  - "**/app/views/**/*.erb"
  - "**/app/helpers/**/*.rb"
---
# Rails views and helpers

- Use `sanitize` for user-supplied HTML, not `raw` or `html_safe`; `html_safe` inserts the string with no escaping and the Rails docs say it should never be called on user input.
