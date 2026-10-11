---
paths:
  - "**/*.vue"
---
# Vue reactivity

- Use `ref()` as the primary API for reactive state; `reactive()` holds only objects and loses tracking when reassigned or destructured.
- Read a ref stored in a reactive array or `Map` with `.value`; unwrapping does not happen there.
- Treat a `computed` value as read-only; change the source state it depends on instead.
- Pass a getter to `watch`, as in `watch(() => obj.count, ...)`; `watch(obj.count, ...)` passes a plain number and does not work.
- Read every dependency of an async `watchEffect` before its first `await`; later reads are not tracked.
- Create watchers synchronously during setup; one created in `setTimeout` is not stopped with the component and leaks unless you call its stop handle.
