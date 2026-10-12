---
paths:
  - "**/*.test.ts"
  - "**/*.test.js"
  - "**/*.spec.ts"
  - "**/*.spec.js"
---
# Vue testing

- When a test mounts a component with `@vue/test-utils`, assert on emitted events, props and slots; asserting private state or methods makes the test brittle.
- When a test mounts a component with `@vue/test-utils`, await `trigger()` and `setValue()` before asserting; they return `nextTick`. Use `flushPromises()` for promises from non-Vue code such as API calls.
- Wrap a composable that uses lifecycle hooks or `provide`/`inject` in a host component to test it; one using only reactivity APIs can be called directly.
- When a test uses Pinia, `createTestingPinia()` stubs all actions; pass `stubActions: false` to run them, and `createSpy: vi.fn` under Vitest without `globals: true`.
- Call `setActivePinia(createPinia())` in `beforeEach` to test a store in isolation with a fresh Pinia each time.
