---
paths:
  - "**/*.rb"
  - "**/*.rake"
---
# Ruby style

- Rescue `StandardError` or a specific class, not `Exception`; rescuing `Exception` traps signals and calls to `exit`, so the process needs `kill -9` to stop.
- Avoid the `rescue` modifier (`read_file rescue handle_error($!)`); it catches every `StandardError` and its descendants.
- Do not use `Hash.new([])` or `Hash.new({})`; every missing key shares one default object. Use a `default_proc` or a block that builds a fresh object per key.
