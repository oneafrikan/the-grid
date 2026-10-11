---
paths:
  - "**/wp-content/**/*.php"
---
# WordPress data security

## Input and permissions
- Validate untrusted data before acting on it; use a `sanitize_*()` function such as `sanitize_text_field()` only where validation cannot be specific.
- Check `current_user_can()` with the specific capability before code that changes data; a nonce is not authorization.
- Add `wp_nonce_field()` to forms and `wp_nonce_url()` to action links with a specific action string, and verify with `check_admin_referer()`, `check_ajax_referer()` or `wp_verify_nonce()`.

## Output
- Escape at the point of `echo`, not earlier: `esc_html()` for element text, `esc_attr()` for attributes, `esc_url()` for URLs, `esc_js()` for inline JavaScript, `wp_kses_post()` for allowed HTML.
- Escape a whole attribute value in one `esc_attr()` call (`esc_attr( $prefix . '-box' . $id )`); escaping each variable separately can miss an escape character just before it.
- Use `esc_html__()`, `esc_attr__()` and their `_e` forms for translated output; each combines translation and escaping.

## Database
- Pass every query that contains a variable through `$wpdb->prepare()` with unquoted `%s`, `%d`, `%f` or `%i` placeholders; `prepare()` escapes and quotes the values, which a variable interpolated into the query string skips.
- Put a LIKE wildcard `%` in the substitution argument and escape the term with `$wpdb->esc_like()`; wildcards cannot be written directly in the query string.
- Call a WordPress API function instead of querying the database directly when one exists; direct queries bypass its caching and forward compatibility.
