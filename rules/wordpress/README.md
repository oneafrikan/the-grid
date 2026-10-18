# wordpress

WordPress plugin and theme PHP conventions from the Developer Handbooks: the PHP coding standards, data validation and escaping, nonces and capabilities, `$wpdb->prepare()`, and plugin structure (prefixing, enqueueing, text domains, uninstall). Written fresh, not adapted from another rule set. These files also load alongside the `php` pack.

## Path scope and its gap

Rules load only on PHP files under `wp-content/`. Every other glob tried (`**/{plugins,themes,mu-plugins}/**/*.php`, `**/class-*.php`, `**/functions.php`, `**/uninstall.php`) also matches non-WordPress PHP such as CakePHP `plugins/` directories, Drupal and Joomla `themes/` trees and Composer libraries, so the review rejected them.

Remaining gap, which is large: most plugin and theme repositories have no `wp-content/` directory, so their PHP files (the main plugin file `my-plugin.php`, `functions.php`, `uninstall.php`, `inc/helpers.php`, `class-*.php`) match no glob and get only the `php` pack. The design inventory listed those wider globs plus `**/wp-config.php` and `**/{theme,block}.json`; widening them is a human decision between coverage and loading these rules on non-WordPress PHP.

These files also load on vendored third-party code (`vendor/`, third-party plugins under `wp-content/`); the glob cannot exclude them.

## Sources

| Rule file | Source |
|---|---|
| standards.md | https://developer.wordpress.org/coding-standards/wordpress-coding-standards/php/ |
| security.md | https://developer.wordpress.org/apis/security/data-validation/ https://developer.wordpress.org/apis/security/sanitizing/ https://developer.wordpress.org/apis/security/escaping/ https://developer.wordpress.org/apis/security/nonces/ https://developer.wordpress.org/apis/security/user-roles-and-capabilities/ https://developer.wordpress.org/reference/classes/wpdb/prepare/ https://developer.wordpress.org/coding-standards/wordpress-coding-standards/php/ |
| structure.md | https://developer.wordpress.org/plugins/plugin-basics/best-practices/ https://developer.wordpress.org/plugins/plugin-basics/uninstall-methods/ https://developer.wordpress.org/plugins/javascript/enqueuing/ https://developer.wordpress.org/plugins/internationalization/how-to-internationalize-your-plugin/ |
