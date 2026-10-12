# react

React conventions: Rules of Hooks, Effects, state placement, the Server Components boundary, XSS and Server Functions, and Testing Library queries. Condensed from affaan-m/ECC's 31 KB React rules to the parts a cited react.dev or Testing Library page supports.

## Scope

- `hooks.md`, `patterns.md` and `security.md` load on `.tsx` and `.jsx` files. Custom Hooks in plain `.ts` or `.js` files are not matched.
- `testing.md` loads on `*.test.*` and `*.spec.*` files with a `.tsx` or `.jsx` extension. Its first bullet is conditional on the project using Testing Library; the other bullets name Testing Library APIs.
- Server Function bullets (`security.md`) sit on `.tsx` and `.jsx`; a separate actions file written as `.ts` is not matched.
- The `Server Components` bullets in `patterns.md` are conditional on the project using React Server Components.
- Bullets about writing a composable (Hook) load only when a `.tsx` or `.jsx` file is open, so they reach the author only while consuming it.
- TypeScript rules (no `React.FC`, prop typing) are not covered here; `typescript` is the pack for type rules.

## Sources

| Rule file | Source |
|---|---|
| hooks.md | https://react.dev/reference/rules/rules-of-hooks https://react.dev/learn/you-might-not-need-an-effect https://react.dev/learn/synchronizing-with-effects https://react.dev/learn/removing-effect-dependencies https://react.dev/reference/react/useMemo |
| patterns.md | https://react.dev/learn/choosing-the-state-structure https://react.dev/learn/sharing-state-between-components https://react.dev/reference/rules/components-and-hooks-must-be-pure https://react.dev/learn/rendering-lists https://react.dev/reference/rsc/use-client https://react.dev/reference/rsc/server-components |
| security.md | https://react.dev/reference/react-dom/components/common https://react.dev/reference/rsc/use-server |
| testing.md | https://testing-library.com/docs/queries/about https://testing-library.com/docs/user-event/intro |

## Adaptation notes

Adapted from affaan-m/ECC (MIT), see rules/THIRD_PARTY_NOTICES.txt. Source: `rules/react/` at commit `ef648e0`. Nothing was copied verbatim; every bullet is rewritten from, and traced to, the cited sources.

| ECC file | Used for | What was kept or dropped |
|---|---|---|
| hooks.md | hooks.md | Kept: Rules of Hooks, "when not to use an Effect", cleanup, `useMemo` as optimization only. Dropped: `useSyncExternalStore`, `useRef` and React 19 sections, the lint-configuration section and the custom-Hook template. |
| patterns.md | patterns.md | Kept: state placement, keys, the Server and Client boundary. Dropped: lifting state up and the state-setter rule (basic React, reviewer B4),  container and presentational split, compound components, portals, form library choices, Suspense and error-boundary templates, the Next.js and React Native pointer sections and the skill reference. |
| security.md | security.md | Kept: `dangerouslySetInnerHTML` and Server Function input validation. Dropped: URL-scheme, `target="_blank"`, env-var, prototype-pollution, SSR-injection, source-map and third-party sections (no cited react.dev page states them), the CSP section (see `web`) and the agent-support section. |
| testing.md | testing.md | Kept: query priority and async queries. Dropped: the MSW, Playwright and Cypress sections, snapshot advice, setup helpers, accessibility-assertion helpers, the coverage-targets section and the skill reference. |
| coding-style.md | none | Dropped: file extensions, naming, component shape, JSX and import layout are house style; the Server and Client boundary moved to patterns.md. |
