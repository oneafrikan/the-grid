# vue

Vue 3 conventions: `<script setup>`, style guide essentials, reactivity, composables, XSS, and test utilities. Adapted from affaan-m/ECC's Vue rules, then cut to what a cited vuejs.org, Test Utils or Pinia page supports.

## Scope

- `style.md`, `reactivity.md`, `patterns.md` and `security.md` load on `.vue` files only. Composables in plain `.ts` or `.js` files are not matched.
- `testing.md` loads on `*.test.*` and `*.spec.*` files with a `.ts` or `.js` extension, which also matches non-Vue tests. Each bullet therefore opens with its trigger ("When a test mounts a component with `@vue/test-utils`") or names a Vue API, so it does not apply to other tests.
- Bullets about writing a composable (Hook) load only when a `.vue` file is open, so they reach the author only while consuming it.
- Bullets name a minimum version where the cited page gives one.
- Vue 3 only. Vue 2 and the Options API are not covered.

## Sources

| Rule file | Source |
|---|---|
| style.md | https://vuejs.org/api/sfc-script-setup.html https://vuejs.org/style-guide/rules-essential https://vuejs.org/guide/essentials/conditional.html |
| reactivity.md | https://vuejs.org/guide/essentials/reactivity-fundamentals.html https://vuejs.org/guide/essentials/computed.html https://vuejs.org/guide/essentials/watchers.html |
| patterns.md | https://vuejs.org/guide/essentials/lifecycle.html https://vuejs.org/guide/reusability/composables.html https://vuejs.org/guide/components/provide-inject.html |
| security.md | https://vuejs.org/guide/best-practices/security.html |
| testing.md | https://vuejs.org/guide/scaling-up/testing.html https://test-utils.vuejs.org/guide/advanced/async-suspense https://pinia.vuejs.org/cookbook/testing.html |

## Adaptation notes

Adapted from affaan-m/ECC (MIT), see rules/THIRD_PARTY_NOTICES.txt. Source: `rules/vue/` at commit `ef648e0`. Nothing was copied verbatim; every bullet is rewritten from, and traced to, the cited sources.

| ECC file | Used for | What was kept or dropped |
|---|---|---|
| coding-style.md | style.md, reactivity.md | Kept: `<script setup>`, `defineProps`, `defineModel`, `v-for` keys, `v-if` with `v-for`, `ref` and `reactive` limits, `computed` and `watch` rules. Dropped: block order, file naming, the Prettier, ESLint and `vue-tsc` mandates, the `toRefs` and `storeToRefs` advice (not on a cited page), the 3.4 `computed` equality note and `nextTick` DOM advice. Also dropped after review: the `computed` side-effect bullet and the "no `<script>` in templates" bullet (no hazard stated on the cited page), `scoped` on every component (the style guide accepts other strategies) and the snapshot-test bullet (not tied to a Vue API). |
| patterns.md | patterns.md | Kept: composable inputs and outputs, `provide` and `inject`. Dropped: Feature-Sliced Design, Pinia store style, `vue-router` guards and `vue-query` key advice (framework-library choices, no vuejs.org page). |
| security.md | security.md | Kept: untrusted templates, `v-html`, URL, style and event injection. Dropped: DOMPurify and `@braintree/sanitize-url` recommendations (the guide names backend sanitization), `VITE_*` env-var and httpOnly cookie advice (build-tool and session topics). |
| testing.md | testing.md | Kept: public-interface testing, async helpers, composable host components, Pinia test setup. Dropped: stack and `happy-dom` setup, `shallowMount` versus `mount`, mount-config option list, `RouterLinkStub`. |
| hooks.md | none | Dropped: advice about Claude Code hooks, not Vue. |
