---
paths:
  - "**/*.html"
  - "**/*.astro"
---
# Semantic HTML and accessibility

- Use `<button>` for actions and `<a href>` for navigation; a `div` or `href="#"` link with `onclick` loses native keyboard operation.
- Give every form control a `<label for>` that matches its `id`, so the label is associated with the control and a click on it activates the control.
- Set `alt=""` on purely decorative `<img>`; without `alt` many screen readers read out the whole image URL.
- Set `lang` on `<html>` so the page's default language can be determined programmatically (WCAG 3.1.1).
- Provide a way to bypass repeated blocks, for example a link at the top of the page to the main content (WCAG 2.4.1).
- Use only `tabindex="0"` or `tabindex="-1"`; a value above 0 makes keyboard navigation difficult by overriding document order.
- Add ARIA roles only where no HTML element has the semantics; ARIA changes what the accessibility API exposes, not behaviour.
