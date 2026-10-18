# golang

Go conventions: error wrapping, context and goroutine lifetimes, standard-library security pitfalls, `testing` package behaviour. Adapted from affaan-m/ECC's Go rules, then cut to what a cited official source supports.

## Scope

- `style.md`, `patterns.md` and `security.md` load on `**/*.go`; every bullet applies to any Go source file.
- `testing.md` loads on `*_test.go` only.
- `modules.md` loads on `go.mod` only; its bullets do not apply to source files. `go.sum` is not matched.
- `**/*.go` also loads on vendored code and on `_test.go` files, so the style, patterns and security bullets apply there too. `go.work` is not matched.
- Framework and application-layout rules (HTTP routers, ORMs) are not covered.

## Sources

| Rule file | Source |
|---|---|
| style.md | https://go.dev/wiki/CodeReviewComments https://go.dev/blog/go1.13-errors https://pkg.go.dev/fmt |
| patterns.md | https://pkg.go.dev/context https://go.dev/blog/context-and-structs https://go.dev/wiki/CodeReviewComments https://go.dev/wiki/LoopvarExperiment |
| security.md | https://pkg.go.dev/math/rand https://pkg.go.dev/text/template https://go.dev/doc/database/sql-injection https://pkg.go.dev/os/exec https://pkg.go.dev/crypto/tls https://pkg.go.dev/net/http |
| testing.md | https://pkg.go.dev/testing |
| modules.md | https://go.dev/ref/mod |

## Adaptation notes

Adapted from affaan-m/ECC (MIT), see rules/THIRD_PARTY_NOTICES.txt. Source: `rules/golang/` at commit `ef648e0`. Nothing was copied verbatim; every bullet is rewritten from, and traced to, the cited sources.

| ECC file | Used for | What was kept or dropped |
|---|---|---|
| coding-style.md | style.md | Kept: error wrapping with `%w` (rewritten from the Go blog, including when not to wrap). Dropped: the `gofmt`/`goimports` mandate (tooling the toolchain already provides), "accept interfaces, return structs" as a slogan (replaced by the Code Review Comments interface-placement rule in patterns.md), the "keep interfaces to 1-3 methods" rule (no cited source), `Receiver Type` mixing advice (stated on the Code Review Comments page, but as a style preference with no failure mode; left out), the "See skill" pointer. |
| patterns.md | patterns.md | Kept: the small-interfaces topic (as interface placement). Dropped: functional options and constructor dependency injection (application design, not language convention), the "See skill" pointer. Added from the sources: context handling, goroutine lifetimes, loop variable capture. |
| security.md | security.md | Kept: the `context` topic (moved to patterns.md, rewritten from the `context` package docs). Dropped: the `os.Getenv` secret example, the `gosec` mandate (no cited Go source names it), the "always use `context`" absolute. Added from the standard-library documentation: `crypto/rand`, `html/template`, SQL placeholders, `os/exec`, `InsecureSkipVerify`, HTTP timeouts. |
| testing.md | testing.md | Dropped: the `-race` and coverage commands (running tests is a workflow step, and the race detector finds only races that run), the table-driven tests heading (no Go documentation states a pitfall to write down), the coverage command and target, "always run" phrasing, the "See skill" pointer. Added from the `testing` package docs: `t.Helper`, `t.TempDir`, `FailNow`, `t.Setenv`, `B.Loop`. |
| hooks.md | none | Dropped: advice about Claude Code hooks, not Go. |

The `go.mod` bullets are new, from go.dev; `govulncheck` is not covered (a scan step, not a code convention). ECC's `go.mod` and `go.sum` path scoping is replaced by per-file scoping.
