---
paths:
  - "**/*.css"
  - "**/*.scss"
  - "**/*.sass"
  - "**/*.less"
---
# CSS

## Custom properties
- Register a custom property with `@property` when it needs a type, a controlled `inherits` or an `initial-value`; an invalid value then falls back to `initial-value`.

## Motion
- Prefer animating `transform` and `opacity`; before animating any other property, check its impact on the rendering pipeline and avoid properties that trigger layout or paint (such as `top` or `left`) unless it is absolutely necessary.
- Add a `@media (prefers-reduced-motion: reduce)` override that tones down scaling or panning animation, which can trigger vestibular motion disorders.
- Set `will-change` only as a last resort for an existing performance problem; on many elements it slows the page down.

## Focus and targets
- Keep a visible focus indicator when you restyle `:focus`; WCAG 2.4.7 (Focus Visible) requires one in keyboard operation.
- Size pointer targets at least 24 by 24 CSS pixels with `min-width` and `min-height` (WCAG 2.5.8), unless an exception applies.
