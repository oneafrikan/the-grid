---
paths:
  - "**/*.tsx"
  - "**/*.jsx"
---
# React state, lists and Server Components

## State
- Do not copy a prop into `useState` unless later changes should be ignored; `useState(color)` keeps only the first value, so name such a prop `initialColor`.
- Keep state flat and free of duplicated data; deeply nested or duplicated state is hard to keep in sync.
- Do not run side effects such as assigning `document.title` during render; React can render a component several times.

## Lists
- Use a stable id such as `key={item.id}`; an array index breaks when items are inserted, deleted or reordered, and `Math.random()` remounts every item.

## Server Components
- When the project uses React Server Components, put `'use client'` at the very top of any file that uses `useState` or an event handler such as `onClick`.
- Pass only serializable props from a Server Component to a Client Component; class instances and non-global `Symbol` values are not supported.
- Make a Server Component `async` and `await` its data in render; async components are not supported on the client.
