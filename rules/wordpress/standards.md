---
paths:
  - "**/wp-content/**/*.php"
---
# WordPress PHP coding standards

## When the code follows the WordPress coding standards (mandatory in core, encouraged for plugins and themes)
- Indent with real tabs and align mid-line text with spaces; spaces for indentation do not match the standard.
- Put a space inside parentheses and inside array brackets that hold a variable (`foo( $bar )`, `$x[ $i ]`); brackets holding a literal take none (`$x['key']`).
- Declare arrays with `array( 1, 2 )`; the standard requires the long syntax.
- Put the literal or constant on the left in `==`, `!=`, `===` and `!==` comparisons (`if ( true === $the_force )`); a mistyped `=` is then a parse error instead of an assignment.
- Prefix class files with `class-` and use hyphens (`class-wp-error.php`); name functions and variables in lowercase with underscores and classes `Capitalized_Words`.
- Use `elseif`, not `else if`; `else if` breaks the colon syntax of `if` blocks.
- Use `require_once` for unconditional includes; `include_once` only warns on a missing file and execution continues.
