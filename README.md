# terraposh

PowerShell wrapper for running Terraform. This module takes advantage of [TF_CLI_ARGS and TF_CLI_ARGS_name](https://www.terraform.io/docs/commands/environment-variables.html#tf_cli_args-and-tf_cli_args_name) environment variables natively supported by Terraform.

In addition, it will automatically sequence the needed order of operations for commands. As an example, if you use `terraposh plan` or `tpp`, it will automatically sequence the `terraform init` --> `terraform workspace` --> `terraform plan` commands for you.

For [Terraform workspaces](https://www.terraform.io/docs/state/workspaces.html), the default behvior of `terraposh` is to use the current `git branch` name as the workspace. You can also manually provide one via the `-Workspace` parameter. If the workspace doesn't exist, it will make it for you. When destroying a state via `terraposh destroy`, `tpd`, or `tpda` the workspace will also be deleted and set back to the `default` workspace.

## Usage examples

### terraform plan

> `terraposh plan`

> `tpp`

### terraform apply

> `terraposh apply`

> `tpa`

### terraform destroy

> `terraposh destroy`

> `tpd`

> `tpda` inludes `-auto-approve` and will not prompt for confirmation
