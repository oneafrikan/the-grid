# typescript

TypeScript and JavaScript conventions: strict compiler options, types at runtime boundaries, errors and promises. Adapted from affaan-m/ECC's TypeScript rules, then cut to what a cited official source supports.

## Scope

- Bullets name a minimum version where the cited page gives one.
- `style.md` loads on `.ts`, `.tsx`, `.mts` and `.cts` files only (its bullets are about types).
- `patterns.md` loads on those and on `.js`, `.jsx`, `.mjs` and `.cjs` files.
- `tsconfig.md` loads on `tsconfig*.json`; it is a separate file because its bullets do not apply to source files. `jsconfig.json` is not matched, and solution-style or base tsconfigs match too, so the `strict` bullet is scoped to the file that holds `compilerOptions`.
- `testing.md` loads on `*.test.*` and `*.spec.*` files with a JavaScript or TypeScript extension. The one bullet is Jest behaviour (`expect.assertions`) and sits under a "When tests run on Jest" heading; other runners are not covered. The "await every promise" test advice is not repeated here because `patterns.md` already covers it on the same files.
- React and web rules belong to the `react` and `web` packs, not here.

## Sources

| Rule file | Source |
|---|---|
| style.md | https://typescript-eslint.io/rules/no-explicit-any/ https://google.github.io/styleguide/tsguide.html https://www.typescriptlang.org/tsconfig/ https://www.typescriptlang.org/docs/handbook/2/narrowing.html https://www.typescriptlang.org/docs/handbook/2/everyday-types.html |
| patterns.md | https://google.github.io/styleguide/tsguide.html https://typescript-eslint.io/rules/only-throw-error/ https://typescript-eslint.io/rules/no-floating-promises/ |
| tsconfig.md | https://www.typescriptlang.org/tsconfig/ https://www.typescriptlang.org/docs/handbook/modules/guides/choosing-compiler-options.html |
| testing.md | https://jestjs.io/docs/asynchronous |

## Adaptation notes

Adapted from affaan-m/ECC (MIT), see rules/THIRD_PARTY_NOTICES.txt. Source: `rules/typescript/` at commit `ef648e0`. Nothing was copied verbatim; every bullet is rewritten from, and traced to, the cited sources.

| ECC file | Used for | What was kept or dropped |
|---|---|---|
| coding-style.md | style.md, patterns.md, tsconfig.md | Kept: the `unknown` over `any` topic, narrowing a caught error, boundary validation (as type predicates instead of Zod), the async/await error topic. Dropped: explicit types on public APIs, interface-versus-type and enum guidance (the TypeScript handbook calls this personal preference), the React props and `React.FC` section (belongs to `react`), JSDoc for JS files, the Immutability section, the Zod mandate, the logger example, the `console.log` ban. Added from the sources: `strict`, `module` and `moduleResolution`, `for...of`, throwing `Error` objects, floating promises. |
| patterns.md | none | Dropped: the API response envelope, `useDebounce` hook and repository pattern are application designs, not language conventions. |
| security.md | none | Dropped: the hardcoded-secret example and the security-reviewer skill pointer; no cited TypeScript source states either. |
| testing.md | testing.md | Dropped: the Playwright mandate and the e2e-runner agent pointer. The async-test bullets are new, from the Jest documentation. |
| hooks.md | none | Dropped: advice about Claude Code hooks, not TypeScript. |
