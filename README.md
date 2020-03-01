# terraposh

PowerShell wrapper for running Terraform. This module takes advantage of [TF_CLI_ARGS and TF_CLI_ARGS_name](https://www.terraform.io/docs/commands/environment-variables.html#tf_cli_args-and-tf_cli_args_name) environment variables natively supported by Terraform.

In addition, it will automatically sequence the needed order of operations for commands. As an example, if you use `terraposh plan` or `tpp`, it will automatically sequence the `terraform init` --> `terraform workspace` --> `terraform plan` commands for you.

For [Terraform workspaces](https://www.terraform.io/docs/state/workspaces.html), the default behvior of `terraposh` is to use the current `git branch` name as the workspace. You can also manually provide one via the `-Workspace` parameter. If the workspace doesn't exist, it will make it for you. When destroying a state via `terraposh destroy`, `tpd`, or `tpda` the workspace will also be deleted and set back to the `default` workspace.

## Usage examples

```powershell
Import-Module 'terraposh.psd1' -Force
```

- Plan, apply, and destroy commands will all perform a `terraform init` automatically.
- If a workspace is not provided, the current git branch will be used via `git rev-parse --abbrev-ref HEAD`
- By default, the working directory will be assumed to be the `Directory`

### terraform plan

- `terraposh plan`
- `tpp`

### terraform apply

- `terraposh apply`
- `tpa`

### terraform destroy

- `terraposh destroy`
- `tpd`
- `tpda` inludes `-auto-approve` and will not prompt for confirmation

## Terraposh configuration

When a `terraposh` command is executed, it will look for a config file. This config file is a JSON file containing the values to populate Terraform CLI environment variables. A default one is provided within the module with empty values. The search order for a config is:

1. `-ConfigFile` parameter
2. `TERRAPOSH_CONFIG_JSON` environment variable
3. `.terraposh.config.json` default config file from this repo

The config file can contain any number of `TF_CLI_ARGS` and they will all be loaded.  An example would be:

```json
{
    "TF_CLI_ARGS_init": "-backend=true -upgrade=true -backend-config=backend.tfvars -reconfigure",
    "TF_CLI_ARGS_plan": "-detailed-exitcode -parallelism=20 -out=.terraform/plan.bin -var-file=development.tfvars",
    "TF_CLI_ARGS_apply": "-parallelism=20 .terraform/plan.bin",
    "TF_CLI_ARGS_destroy": "-parallelism=20 -var-file=development.tfvars",
    "TF_CLI_ARGS_fmt": "-recursive",
    "TF_CLI_ARGS_output": "-json"
}
```

## Commands

All functions support the same params.

```powershell
[string]$TerraformCommand # Will be suffixed to command (required only for base terraposh command) via terraform <TerraformCommand>
[string]$ConfigFile       # Terraposh config file path
[string]$Directory        # Directory of Terraform root module code
[string]$Workspace        # Terraform workspace name
[switch]$Explicit         # Used to bypass automatic sequencing of init, workspace, <command> and will instead just run the provided command only
```

### `terraposh` or `Invoke-Terraposh`

```powershell
NAME
    Invoke-Terraposh

SYNTAX
    Invoke-Terraposh
        [-TerraformCommand] <string>
        [-ConfigFile <string>]
        [-Directory <string>]
        [-Workspace <string>]
        [-Explicit]

ALIASES
    terraposh
```

### `tpp` or `Invoke-TerraposhPlan`

```powershell
NAME
    Invoke-TerraposhPlan

SYNTAX
    Invoke-TerraposhPlan
        [[-TerraformCommand] <string>]
        [-ConfigFile <string>]
        [-Directory <string>]
        [-Workspace <string>]
        [-Explicit]

ALIASES
    tpp
```

### `tpa` or `Invoke-TerraposhApply`

```powershell
NAME
    Invoke-TerraposhApply

SYNTAX
    Invoke-TerraposhApply
        [[-TerraformCommand] <string>]
        [-ConfigFile <string>]
        [-Directory <string>]
        [-Workspace <string>]
        [-Explicit]

ALIASES
    tpa
```

### `tpd` or `Invoke-TerraposhDestroy`

```powershell
NAME
    Invoke-TerraposhDestroy

SYNTAX
    Invoke-TerraposhDestroy
        [[-TerraformCommand] <string>]
        [-ConfigFile <string>]
        [-Directory <string>]
        [-Workspace <string>]
        [-Explicit]

ALIASES
    tpd
```

### `tpda` or `Invoke-TerraposhDestroyAutoApprove`

```powershell
NAME
    Invoke-TerraposhDestroyAutoApprove

SYNTAX
    Invoke-TerraposhDestroyAutoApprove
        [[-TerraformCommand] <string>]
        [-ConfigFile <string>]
        [-Directory <string>]
        [-Workspace <string>]
        [-Explicit]

ALIASES
    tpda
```
