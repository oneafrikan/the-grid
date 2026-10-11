---
paths:
  - "**/*.go"
---
# Go security

- Generate tokens, keys and session IDs with `crypto/rand`; `math/rand` output "might be easily predictable" and is documented as unsuitable for security-sensitive work.
- Render HTML with `html/template`, not `text/template`; `text/template` does not auto-escape, so untrusted values become injected markup.
- Pass SQL values as arguments to `db.Query` and `db.Exec` with the driver's placeholders (`?` or `$1`); building the statement with `fmt.Sprintf` is an SQL injection risk.
- Pass each `exec.Command` argument as a separate string; `os/exec` does not invoke a shell, and building an `sh -c` string from input reintroduces shell injection.
- Leave `InsecureSkipVerify` unset in `tls.Config` outside tests; `true` accepts any certificate and exposes the connection to machine-in-the-middle attacks.
- Set `Timeout` on `http.Client` and `ReadHeaderTimeout` on `http.Server`; zero means no timeout, so a stalled peer holds the connection forever.
