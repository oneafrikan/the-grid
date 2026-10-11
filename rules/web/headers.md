---
paths:
  - "**/_headers"
  - "**/.htaccess"
  - "**/nginx.conf"
---
# Security response headers

- Send `Strict-Transport-Security` over HTTPS only; browsers ignore it over HTTP so that a man-in-the-middle cannot alter it.
- Add `preload` to `Strict-Transport-Security` only with `max-age` of at least `31536000` and `includeSubDomains`; the preload list requires both.
- Set `frame-ancestors` in the `Content-Security-Policy` header; the directive is not supported in a `<meta>` element.
- Roll out a new policy with `Content-Security-Policy-Report-Only` first; it shows which violations would have occurred.
