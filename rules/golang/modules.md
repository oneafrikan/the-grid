---
paths:
  - "**/go.mod"
---
# go.mod

- Set the `go` directive to the oldest Go version the module supports; since Go 1.21 it is a mandatory minimum, and toolchains refuse to use a module that declares a newer version.
- Put `replace` directives only in the main module's `go.mod`; they are ignored in `go.mod` files of dependencies, so a library relying on one breaks for its consumers.
