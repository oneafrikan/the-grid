---
paths:
  - "**/*_test.go"
---
# Go testing

- Call `t.Helper()` at the top of test helper functions so failures are reported at the calling line, not inside the helper.
- Create scratch directories with `t.TempDir()`; Go removes it when the test and all its subtests complete.
- Call `t.Fatal` and `t.FailNow` only from the goroutine running the test; `FailNow` does not stop goroutines the test started, so use `t.Error` inside them.
- Do not call `t.Setenv` in a test that calls `t.Parallel()`; `Setenv` changes the whole process, so it cannot be used in parallel tests.
- When the module targets Go 1.24 or later, write benchmark loops as `for b.Loop()`; the `testing` package says new benchmarks should prefer `B.Loop` over `b.N`.
