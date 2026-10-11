---
paths:
  - "**/*.tf"
---
# Terraform modules

## Structure
- Place nested modules under the `modules/` subdirectory and call them with relative paths such as `./modules/consul-cluster`.
- Split complex behavior into several small nested modules that the caller can compose, rather than modules calling each other.
- Put usage examples under the root `examples/` directory, with each `module` block's `source` set to the address an external caller would use.

## Providers and versions
- Omit `provider` blocks from any module that other modules call; a module with its own provider configuration cannot use `count`, `for_each` or `depends_on`.
- Declare the providers a module needs in its own `required_providers` block, with a source and a version constraint.
- Use `configuration_aliases` in `required_providers` when a module needs additional provider configurations.
- Constrain every registry module with `version`; unconstrained, upgrades can change infrastructure unexpectedly.
- Omit `version` on modules with a local path `source`; they share the caller's version.
