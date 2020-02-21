#Requires -Version 6

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$VerbosePreference = 'Continue'

function Invoke-Terraposh {
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$TerraformCommand,
        [string]$ConfigFile,
        [string]$Directory,
        [string]$Workspace,
        [switch]$Explicit
    )

    $TerraformCommand

    # Load terraposh config
    $Config = Get-Config -File $ConfigFile

    # Set Terraform environment variables
    Set-TerraformEnvironmentVariables -Config $Config

    # Push to directory
    if (-not [string]::IsNullOrWhiteSpace($Directory)) {
        $Directory = (Resolve-Path -Path $Directory).Path
        Push-Location -Path $Directory -StackName 'terraposh'
    }

    try {
        $TerraformCommand = $TerraformCommand.Trim()

        # If not explicit, sequence for laziness
        if ($Explicit) {
            Invoke-TerraformCommand -Command $TerraformCommand
        }
        else {
            switch -Regex ($TerraformCommand) {
                '^plan|^apply' {
                    Invoke-TerraformCommand -Command 'init'
                    Set-TerraformWorkspace -Workspace $Workspace
                    Invoke-TerraformCommand -Command $TerraformCommand
                }
                '^destroy' {
                    Invoke-TerraformCommand -Command 'init'
                    $Workspace = Set-TerraformWorkspace -Workspace $Workspace -PassThru
                    Invoke-TerraformCommand -Command $TerraformCommand
                    Set-TerraformWorkspace -Workspace 'default'
                    Invoke-TerraformCommand -Command "workspace delete ${Workspace}"
                }
                '^output' { Invoke-TerraformCommand -Command $TerraformCommand } # output to a directory from config
                # '^validate' { Invoke-TerraformCommand -Command $TerraformCommand } # need to consider init -backend=false
                default { Invoke-TerraformCommand -Command $TerraformCommand }
            }
        }
    }
    catch {
        throw $_
    }
    finally {
        Pop-Location -StackName 'terraposh' -ErrorAction SilentlyContinue
    }
}

function Invoke-TerraformCommand {
    param (
        [string]$Command
    )

    $TerraformCommand = "terraform ${Command}"

    Write-Verbose -Message $TerraformCommand
    Invoke-Expression -Command $TerraformCommand

    if ($LASTEXITCODE -notin @(0, 2)) {
        $ErrorMessage = "Terraform command failed with exit code: ${LASTEXITCODE}"
        throw ($ErrorMessage, $TerraformCommand -join "`n")
    }
}

function Get-Config {
    param (
        [string]$File
    )

    $SearchLoctaions = @(
        $File,
        $env:TERRAPOSH_CONFIG_JSON
        # TODO: Support merge of a .terraposh.config.json found it working directory
    )

    # Default config
    $ConfigFilePath = Join-Path -Path $PSScriptRoot -ChildPath '.terraposh.config.json'

    foreach ($SearchLoctaion in $SearchLoctaions) {
        if ([string]::IsNullOrWhiteSpace($SearchLoctaion)) {
            continue
        }

        if (Test-Path -Path $SearchLoctaion) {
            
            $ConfigFilePath = $SearchLoctaion
            break
        }

        throw (New-Object -TypeName System.IO.FileNotFoundException -ArgumentList "Config file not found: ${SearchLoctaion}")
    }

    Write-Verbose -Message "Config file: ${ConfigFilePath}"
    $Config = Get-Content -Path $ConfigFilePath -Raw | ConvertFrom-Json -AsHashtable

    return $Config
}

function Set-TerraformEnvironmentVariables {
    param (
        [hashtable]$Config
    )

    $TfCliArgsEnvVars = $Config.Keys -match '^TF_CLI_ARGS'

    foreach ($TfCliArgsEnvVar in $TfCliArgsEnvVars) {
        Set-Item -Path "Env:\${TfCliArgsEnvVar}" -Value $Config[$TfCliArgsEnvVar]
    }
}

function Get-GitBranchName {
    $GitCommand = 'git rev-parse --abbrev-ref HEAD'
    $GitBranchName = Invoke-Expression -Command $GitCommand

    if ($LASTEXITCODE -ne 0) {
        $ErrorMessage = "Git command failed with non-zero exit code: ${LASTEXITCODE}"
        throw ($ErrorMessage, $GitCommand -join "`n")
    }

    if ([string]::IsNullOrWhiteSpace($GitBranchName)) {
        $ErrorMessage = "Git branch name returned null."
        throw ($ErrorMessage, $GitCommand -join "`n")
    }

    return $GitBranchName
}

function Get-TerraformWorkspaceName {
    $Workspace = Get-GitBranchName

    return $Workspace
}

function Set-TerraformWorkspace {
    param (
        [string]$Workspace,
        [switch]$PassThru
    )

    if ([string]::IsNullOrWhiteSpace($Workspace)) {
        $Workspace = Get-TerraformWorkspaceName
    }
    
    Write-Verbose -Message "Workspace name: ${Workspace}"

    $CurrentWorkspace = Invoke-TerraformCommand -Command 'workspace show'
    Write-Verbose -Message "Current workspace: ${CurrentWorkspace}"

    if ($Workspace -eq $CurrentWorkspace) {
        Write-Verbose -Message "Current workspace is already ${Workspace}"
    }
    else {
        $CurrentWorkspacesAvailable = Invoke-TerraformCommand -Command 'workspace list' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        Write-Verbose -Message "Current workspaces available: $($CurrentWorkspacesAvailable -join ', ')"

        if ($CurrentWorkspacesAvailable -cmatch $Workspace) {
            Write-Verbose "${Workspace} already exists, selecting it"
            Invoke-TerraformCommand -Command "workspace select ${Workspace}" | Out-Null
        }
        else {
            Write-Verbose "${Workspace} doesn't exist, creating it"
            Invoke-TerraformCommand -Command "workspace new ${Workspace}" | Out-Null
        }
    }

    if ($PassThru) {
        return $Workspace
    }
}

# Create aliases and export members
Set-Alias -Name 'terraposh' -Value 'Invoke-Terraposh'
Export-ModuleMember -Function 'Invoke-Terraposh' -Alias 'terraposh'
