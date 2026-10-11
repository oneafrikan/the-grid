---
paths:
  - "**/*.tf"
---
# Terraform safety

## State and secrets
- Store state in a remote backend or HCP Terraform, and keep the state file out of Git; version control lacks state locking and secure access control, and the state can contain secrets.
- Do not commit `.tfvars` files that contain sensitive information; secrets in configuration also end up in state and plan files.
- Set `sensitive = true` on secret variables and outputs; it hides CLI output only, and the value stays in plain text in state and plan files.
- Use ephemeral values or write-only arguments for temporary secrets; Terraform omits them from state and plan files.
- Change state with `terraform state` commands; the state file is not meant to be edited directly.

## Plan and apply
- In automation, save the plan with `terraform plan -out=FILE` and pass that file to `terraform apply`; a saved plan applies without a prompt.
- Avoid `-auto-approve` unless nobody can change the infrastructure outside Terraform; it includes destructive operations.
- Avoid `-lock=false`; concurrent runs against the same workspace are dangerous.
- Set `prevent_destroy = true` in `lifecycle` on stateful resources; it rejects plans that destroy them, but removing the configuration still destroys them.

## Versions
- In a root module, pin `required_version` and each `required_providers` version, so upgrades never change infrastructure unintentionally.
- Commit `.terraform.lock.hcl`; it records the exact provider versions and hashes.
- Upgrade providers deliberately with `terraform init -upgrade`; otherwise `init` keeps the recorded versions.
