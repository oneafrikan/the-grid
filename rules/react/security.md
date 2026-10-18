---
paths:
  - "**/*.tsx"
  - "**/*.jsx"
---
# React security

- Use `dangerouslySetInnerHTML` only with trusted and sanitized data; raw user-derived HTML introduces an XSS vulnerability.
- When a function is marked `'use server'`, treat its arguments as untrusted input and validate them; callers control them fully.
- Authorize the logged-in user inside every Server Function; each one is an exposed server endpoint callable from client code.
- Put `'use server'` at the top of a file only when every export should be callable from client code; it turns all exports into Server Functions.
