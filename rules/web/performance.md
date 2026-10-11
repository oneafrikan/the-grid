---
paths:
  - "**/*.html"
  - "**/*.astro"
  - "**/*.vue"
  - "**/*.svelte"
---
# Core Web Vitals in markup

- Set `width` and `height` attributes on `<img>` and `<video>`, or reserve space with CSS `aspect-ratio`, so loading media does not shift the layout.
- Never put `loading="lazy"` on the likely LCP image; lazy loading delays its request until layout confirms it is in the viewport.
- Set `fetchpriority="high"` on the likely LCP `<img>` and on no more than one or two images; more makes the priority unhelpful for LCP.
- Reference the LCP image in the initial HTML as an `<img>` so the preload scanner finds it; one set only from CSS or JavaScript needs a `<link rel="preload">`.
- Add `<link rel="preload">` for a web font you know the page needs, and still set `font-display`, since preloading does not guarantee the font is ready.
