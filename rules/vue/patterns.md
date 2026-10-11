---
paths:
  - "**/*.vue"
---
# Vue lifecycle, composables and provide/inject

- Register `onMounted` and other lifecycle hooks synchronously during setup; a hook registered inside `setTimeout` does not work.
- Call composables synchronously in `<script setup>` or `setup()`; Vue needs the active component instance to register hooks and watchers.
- Return a plain object of refs from a composable so callers can destructure it without losing reactivity.
- Normalize composable arguments with `toValue()` inside `watchEffect()` so a ref, a getter or a plain value all work and stay tracked.
- Remove listeners and other side effects set up by a composable in `onUnmounted()`.
- Keep mutations of provided state in the provider and provide an updater function; wrap the value in `readonly()` to block injector mutation.
- Use `Symbol` injection keys when many providers exist, to avoid key collisions.
