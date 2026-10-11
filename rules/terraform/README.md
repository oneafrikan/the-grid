# terraform

Conventions for Terraform configuration: HashiCorp style, module structure and provider
handling, and state, secrets and plan/apply safety. Terraform and its `.tf` / `.tfvars`
files only; OpenTofu is not covered by the cited sources.

## Scope

- All three rule files load on `**/*.tf`.
- `.tfvars` and `.terraform.lock.hcl` are not matched by any glob: a glob for either would
  load every `safety.md` bullet on a file that only one or two of them concern (the
  `.tfvars` and lock-file bullets load when a `.tf` file is read instead).
- Files such as `.tfstate`, `*.tfplan` and `*.tf.json` are not matched by any glob.

## Sources

| Rule file | Source |
|---|---|
| style.md | https://developer.hashicorp.com/terraform/language/style |
| modules.md | https://developer.hashicorp.com/terraform/language/modules/develop/structure https://developer.hashicorp.com/terraform/language/modules/develop/providers https://developer.hashicorp.com/terraform/language/block/module |
| safety.md | https://developer.hashicorp.com/terraform/language/manage-sensitive-data https://developer.hashicorp.com/terraform/language/state https://developer.hashicorp.com/terraform/language/meta-arguments/lifecycle https://developer.hashicorp.com/terraform/cli/commands/plan https://developer.hashicorp.com/terraform/cli/commands/apply https://developer.hashicorp.com/terraform/language/files/dependency-lock https://developer.hashicorp.com/terraform/language/block/terraform https://developer.hashicorp.com/terraform/language/style |
