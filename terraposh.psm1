#Requires -Version 6

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Invoke-Terraposh {
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$TerraformCommand,
        [string]$ConfigFile,
        [string]$Directory,
        [string]$Workspace,
        [switch]$Explicit
    )

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
                    Clear-TerraformEnvironment
                    Invoke-TerraformCommand -Command 'init'
                    Set-TerraformWorkspace -Workspace $Workspace
                    Invoke-TerraformCommand -Command $TerraformCommand
                }
                '^destroy' {
                    Clear-TerraformEnvironment
                    Invoke-TerraformCommand -Command 'init'
                    $Workspace = Set-TerraformWorkspace -Workspace $Workspace -PassThru
                    Invoke-TerraformCommand -Command $TerraformCommand
                    
                    if ($Workspace -ne 'default') {
                        Set-TerraformWorkspace -Workspace 'default'
                        Invoke-TerraformCommand -Command "workspace delete ${Workspace}"
                    }
                }
                default { Invoke-TerraformCommand -Command $TerraformCommand }
            }
        }
    }
    catch {
        throw $_
    }
    finally {
        Pop-Location -StackName 'terraposh' -ErrorAction Ignore
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

function Clear-TerraformEnvironment {
    $TerraformEnvironmentFile = Join-Path -Path $PWD -ChildPath '.terraform' -AdditionalChildPath 'environment'
    Write-Verbose -Message "Clear workspace file: ${TerraformEnvironmentFile}"
    Remove-Item -Path $TerraformEnvironmentFile -ErrorAction Ignore | Out-Null
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
            Write-Verbose -Message "${Workspace} already exists, selecting it"
            Invoke-TerraformCommand -Command "workspace select ${Workspace}" | Out-Null
        }
        else {
            Write-Verbose -Message "${Workspace} doesn't exist, creating it"
            Invoke-TerraformCommand -Command "workspace new ${Workspace}" | Out-Null
        }
    }

    if ($PassThru) {
        return $Workspace
    }
}

# Helper functions
function Invoke-TerraposhPlan {
    param (
        [string]$TerraformCommand,
        [string]$ConfigFile,
        [string]$Directory,
        [string]$Workspace,
        [switch]$Explicit
    )

    $PSBoundParameters.Remove('TerraformCommand') | Out-Null
    Invoke-Terraposh -TerraformCommand "plan ${TerraformCommand}" @PSBoundParameters
}

function Invoke-TerraposhApply {
    param (
        [string]$TerraformCommand,
        [string]$ConfigFile,
        [string]$Directory,
        [string]$Workspace,
        [switch]$Explicit
    )

    $PSBoundParameters.Remove('TerraformCommand') | Out-Null
    Invoke-Terraposh -TerraformCommand "apply ${TerraformCommand}" @PSBoundParameters
}

function Invoke-TerraposhDestroy {
    param (
        [string]$TerraformCommand,
        [string]$ConfigFile,
        [string]$Directory,
        [string]$Workspace,
        [switch]$Explicit
    )

    $PSBoundParameters.Remove('TerraformCommand') | Out-Null
    Invoke-Terraposh -TerraformCommand "destroy ${TerraformCommand}" @PSBoundParameters
}

function Invoke-TerraposhDestroyAutoApprove {
    param (
        [string]$TerraformCommand,
        [string]$ConfigFile,
        [string]$Directory,
        [string]$Workspace,
        [switch]$Explicit
    )

    $PSBoundParameters.Remove('TerraformCommand') | Out-Null
    Invoke-Terraposh -TerraformCommand "destroy -auto-approve ${TerraformCommand}" @PSBoundParameters
}

# Create aliases and export members
$ExportedMembers = @{
    terraposh = 'Invoke-Terraposh'
    tpp       = 'Invoke-TerraposhPlan'
    tpa       = 'Invoke-TerraposhApply'
    tpd       = 'Invoke-TerraposhDestroy'
    tpda      = 'Invoke-TerraposhDestroyAutoApprove'
}

$ExportedMembers.Keys | ForEach-Object { Set-Alias -Name $_ -Value $ExportedMembers[$_] }
Export-ModuleMember -Function '*' -Alias '*'
