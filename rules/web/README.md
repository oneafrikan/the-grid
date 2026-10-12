# web

Browser-platform conventions: semantic HTML and accessibility, CSS, Core Web Vitals in markup, CSP and subresource integrity, and security response headers. Framework-neutral; React and Vue have their own packs. Adapted from affaan-m/ECC's web rules, then cut to what a cited official source supports.

## Scope

- `html.md` and `security.md` load on `.html` and `.astro` files; `performance.md` also loads on `.vue` and `.svelte` (its bullets are about `<img>`, `<video>` and `<link>` tags).
- `css.md` loads on `.css`, `.scss`, `.sass` and `.less` only; it is a separate file because its bullets do not apply to markup.
- `headers.md` loads on `_headers`, `.htaccess` and `nginx.conf` files. Response headers can be set in many other places (framework config, server code, hosting dashboards); those are not covered because no reliable path glob matches them.
- No file loads on `.tsx` or `.jsx`, so a React file gets nothing from this pack. The XSS bullets for React live in the `react` pack and for Vue in the `vue` pack.
- Server-templated `.html` files (Jinja, Django, Angular templates) match; other template files (for example `.j2`, `.blade.php`, `.erb`) are not matched.

## Sources

| Rule file | Source |
|---|---|
| html.md | https://developer.mozilla.org/en-US/docs/Learn_web_development/Core/Accessibility/HTML https://developer.mozilla.org/en-US/docs/Learn_web_development/Core/Accessibility/WAI-ARIA_basics https://developer.mozilla.org/en-US/docs/Web/HTML/Reference/Global_attributes/tabindex https://www.w3.org/WAI/WCAG22/Understanding/language-of-page.html https://www.w3.org/WAI/WCAG22/Understanding/bypass-blocks.html |
| css.md | https://developer.mozilla.org/en-US/docs/Web/CSS/Guides/Cascading_variables/Using_custom_properties https://web.dev/articles/animations-guide https://developer.mozilla.org/en-US/docs/Web/CSS/Reference/At-rules/@media/prefers-reduced-motion https://developer.mozilla.org/en-US/docs/Web/CSS/Reference/Properties/will-change https://www.w3.org/WAI/WCAG22/Understanding/target-size-minimum.html https://www.w3.org/TR/WCAG22/ |
| performance.md | https://web.dev/articles/vitals https://web.dev/articles/optimize-lcp https://web.dev/articles/optimize-cls https://web.dev/articles/optimize-webfont-loading |
| security.md | https://developer.mozilla.org/en-US/docs/Web/HTTP/Guides/CSP https://developer.mozilla.org/en-US/docs/Web/Security/Practical_implementation_guides/CSP https://developer.mozilla.org/en-US/docs/Web/Security/Defenses/Subresource_Integrity https://developer.mozilla.org/en-US/docs/Web/HTML/Reference/Elements/meta/http-equiv |
| headers.md | https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Strict-Transport-Security https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Content-Security-Policy/frame-ancestors https://developer.mozilla.org/en-US/docs/Web/Security/Practical_implementation_guides/CSP https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/X-Content-Type-Options |

## Adaptation notes

Adapted from affaan-m/ECC (MIT), see rules/THIRD_PARTY_NOTICES.txt. Source: `rules/web/` at commit `ef648e0`. Nothing was copied verbatim; every bullet is rewritten from, and traced to, the cited sources.

| ECC file | Used for | What was kept or dropped |
|---|---|---|
| coding-style.md | html.md, css.md | Kept: semantic HTML, custom properties (as `@property` registration), compositor-friendly animation properties. Dropped: the feature-folder layout, the naming section, the design-token example values and the `--ease-out-expo` easing (design taste), the "define tokens on `:root`" bullet and the `<nav>`/`<footer>` landmark bullet (generic, reviewer B4). Added from the sources: accessibility, `@property`, `prefers-reduced-motion`, `will-change`, focus and target size. |
| performance.md | performance.md, css.md | Kept: image dimensions, `loading` and `fetchpriority`, font preload. Dropped: the LCP, INP and CLS thresholds (field-measurement advice that cannot be acted on in the files this pack loads on; web.dev publishes them), `font-display: swap` (the cited page does not describe the value), FCP and TBT targets (not Core Web Vitals), bundle-size budgets (house numbers), the two-font-family limit, dynamic-import advice and the checklist. |
| security.md | security.md, headers.md | Kept: nonce-based CSP (inline scripts and event handlers), SRI, HSTS, `X-Content-Type-Options: nosniff` (in `headers.md`, so a repo with only `nginx.conf` or `_headers` gets it; the `flask` pack keeps its own bullet). Folded: the per-response nonce rule into the nonce bullet of `security.md`. Dropped: the copy-paste CSP block (the source says to adapt it), `X-Frame-Options`, `Referrer-Policy` and `Permissions-Policy` values, the form rules (CSRF, rate limiting, honeypots; no web-platform source) and the third-party audit cadence. XSS bullets moved to `react` and `vue`. |
| patterns.md | none | Dropped: component composition, state-management tool table and data-fetching patterns are framework design, not web-platform conventions. |
| testing.md | none | Dropped: Playwright and screenshot-regression mandates, breakpoint lists, browser matrix and the coverage sentence. |
| design-quality.md, hooks.md | none | Dropped by design: design taste, and advice about Claude Code hooks. |
