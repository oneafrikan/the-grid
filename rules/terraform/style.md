---
paths:
  - "**/*.tf"
---
# Terraform style

## Layout
- Format with `terraform fmt` and check with `terraform validate`.
- In a root module, keep resource and data blocks in `main.tf` until the codebase grows, then split them by logical group (`network.tf`, `storage.tf`).
- In a root module, put `variable`, `output` and `provider` blocks in `variables.tf`, `outputs.tf` and `providers.tf`.
- Keep a single `terraform` block in `terraform.tf` holding `required_version` and `required_providers`.
- Order `variable` and `output` blocks alphabetically.

## Naming and declarations
- Name blocks with a descriptive noun and underscores (`web_server`); omit the resource type from the name, since the address already includes it.
- Declare a `type` and a `description` for every `variable`, and a `description` for every `output`.
- Use `count` for almost identical resources, and `for_each` when arguments need distinct values that an integer cannot derive.
- Put `count` or `for_each` first in a resource, followed by a blank line, then the other arguments; place `depends_on` last.
