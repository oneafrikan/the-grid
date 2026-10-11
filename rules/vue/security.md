---
paths:
  - "**/*.vue"
---
# Vue security

- Use only trusted content as a component `template`; a non-trusted template allows arbitrary JavaScript execution, and server breaches under server-side rendering.
- Bind `v-html` only to HTML known to be safe; user-provided HTML is not safe unless sandboxed in an iframe or shown only to its author.
- Sanitize user-provided URLs in the backend before storing them and binding them to `:href`; an unsanitized `javascript:` URL executes script.
- Bind user styles through `:style` object syntax with specific safe properties, so users cannot supply arbitrary CSS.
- Do not bind user-provided strings to event attributes such as `onclick`; they are JavaScript and a security risk.
