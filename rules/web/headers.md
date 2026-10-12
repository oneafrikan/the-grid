---
paths:
  - "**/_headers"
  - "**/.htaccess"
  - "**/nginx.conf"
---
# Security response headers

- Send `Strict-Transport-Security` over HTTPS only; browsers ignore it over HTTP so that a man-in-the-middle cannot alter it.
- Add `preload` to `Strict-Transport-Security` only with `max-age` of at least `31536000` and `includeSubDomains`; `includeSubDomains` makes all present and future subdomains HTTPS-only, which blocks HTTP-only subdomains.
- Set `frame-ancestors` in the `Content-Security-Policy` header; the directive is not supported in a `<meta>` element.
- Send `X-Content-Type-Options: nosniff` so the browser does not guess a response's MIME type; it blocks script and style loads whose `Content-Type` is not a JavaScript or CSS type.
- Roll out a new policy with `Content-Security-Policy-Report-Only` first; it shows which violations would have occurred.
