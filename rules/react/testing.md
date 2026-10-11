---
paths:
  - "**/*.test.tsx"
  - "**/*.test.jsx"
  - "**/*.spec.tsx"
  - "**/*.spec.jsx"
---
# React Testing Library

- When tests use Testing Library, query with `getByRole` first and `getByLabelText` for form fields; users find elements through the accessibility tree and labels.
- Use `getByTestId` only when role or text matching is impossible; users cannot see or hear test IDs.
- Use `queryBy*` to assert that an element is absent; `getBy*` throws when nothing matches.
- Use `findBy*` for an element that appears asynchronously; it retries until the element is found or a timeout of 1000 ms passes.
- Call `userEvent.setup()` before `render` and `await` each `user-event` call; it simulates a whole user interaction, while `fireEvent` dispatches one DOM event.
