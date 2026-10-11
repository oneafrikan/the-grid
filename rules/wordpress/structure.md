---
paths:
  - "**/wp-content/**/*.php"
---
# WordPress plugin and theme structure

## Names and files
- Prefix every global function, class, constant, global variable, option and transient with a unique prefix of 4 to 5 letters; unprefixed names collide with other plugins.
- Do not start a prefix with `wp_`, `__`, `_` or `WordPress`; core reserves them.
- Reserve `if ( ! function_exists() )` wrappers for shared libraries; if another plugin loads the same function name first, your plugin breaks.
- Start any file that runs code outside class and function definitions, such as the main plugin file, with `if ( ! defined( 'ABSPATH' ) ) { exit; }` to block direct access.
- Begin `uninstall.php` with `defined( 'WP_UNINSTALL_PLUGIN' )` and exit if it is missing; the file is otherwise reachable directly.
- Delete options and custom tables from `uninstall.php` or `register_uninstall_hook()`, not from the deactivation hook, which is for cache and temporary data.

## Scripts and text
- Enqueue scripts from `wp_enqueue_scripts` (front end), `admin_enqueue_scripts` (admin) or `login_enqueue_scripts`, using `wp_enqueue_script()` and `plugins_url()` instead of hardcoded `<script>` tags.
- Pass the text domain as a quoted string literal matching the plugin slug in every `__()` and `_e()` call; without it translations do not work.
- Use `printf()` with `%1$s` style placeholders for translated text containing variables, not concatenated fragments, since placeholder order changes between languages.
