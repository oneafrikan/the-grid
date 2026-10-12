---
paths:
  - "**/*.tsx"
  - "**/*.jsx"
---
# React Hooks and Effects

## Rules of Hooks
- Call Hooks at the top level of a function component or custom Hook, before any early `return`; do not call them in loops, conditions, event handlers or `try`/`catch`/`finally`.
- Call Hooks only from function components and custom Hooks, so all stateful logic stays visible in the source.

## Effects
- Compute derived values during render instead of in `useEffect` plus `setState`; an Effect is for synchronizing with an external system.
- Handle user events in event handlers, not Effects; an Effect cannot tell which button the user clicked.
- Reset a component's state by giving it a `key`, as in `<Profile key={userId} />`, instead of resetting it in an Effect.
- Return a cleanup function from an Effect that connects, subscribes or fetches; in development, Strict Mode remounts once to expose a missing cleanup.
- Ignore or abort stale responses in the cleanup of an Effect that fetches, for example with an `ignore` flag, to avoid race conditions.
- List every reactive value an Effect reads in its dependency array; suppressing `react-hooks/exhaustive-deps` lies to React and risks stale values.
- Treat `useMemo` as a performance optimization only: React may discard the cache, so the code must be correct without it.
