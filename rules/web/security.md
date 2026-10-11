---
paths:
  - "**/*.html"
  - "**/*.astro"
---
# CSP and subresource integrity in markup

- Add `integrity` and `crossorigin="anonymous"` to a `<script>` or `<link>` loaded from another origin; without `crossorigin` the integrity check always fails.
- Protect inline scripts with a `nonce` or a hash in the CSP instead of `'unsafe-inline'`, which defeats much of the purpose of a CSP.
- Replace inline event handler attributes such as `onclick` with `addEventListener`, so a strict CSP can block inline JavaScript.
- When the CSP is delivered in `<meta http-equiv>`, set no other security header there; unrecognised values are ignored and give a false sense of security.
