---
paths:
  - "**/*.go"
---
# Go patterns

## Context
- Pass `context.Context` as the first parameter, named `ctx`; do not store it in a struct field, except in methods that must match an external interface or for backwards compatibility, because it fixes one deadline for every call.
- Call the `cancel` function returned by `context.WithCancel`, `context.WithTimeout` and `context.WithDeadline` (usually `defer cancel()`); failing to call it leaks the child context until the parent is canceled.

## Goroutines and interfaces
- Make clear when each goroutine you start exits; a goroutine blocked on a channel send or receive is never garbage collected, even if the channel is unreachable.
- Define an interface in the package that uses it, not the one that implements it, and return concrete types from constructors; design the implementing package's API so it can be tested through its public API.
- When `go.mod` declares a Go version below 1.22, copy the loop variable (`v := v`) before a closure or goroutine captures it; one variable is shared by every iteration.
