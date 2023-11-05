#Requires -Version 7

using namespace System.Collections
using namespace System.Management.Automation
using namespace System.Web

$ErrorActionPreference = [ActionPreference]::Stop
$ProgressPreference = [ActionPreference]::SilentlyContinue

function Invoke-Terraposh {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$TerraformCommand,
        [string]$ConfigFile,
        [string]$Directory,
        [string]$Workspace,
        [switch]$Explicit,
        [string]$Version,
        [switch]$CreateHardLink
    )

    # Push to directory
    if (-not [string]::IsNullOrWhiteSpace($Directory)) {
        $Directory = (Resolve-Path -Path $Directory).Path
        Push-Location -Path $Directory -StackName 'terraposh'
    }

    try {
        # Load terraposh config
        $Config = Get-Config -File $ConfigFile

        # Set Terraform environment variables
        Set-TerraformEnvironmentVariables -Config $Config

        # Splat
        $TerraformCommandSplat = @{
            Version        = [string]::IsNullOrWhiteSpace($Version) ? $Config.TerraformVersion : $Version
            CreateHardLink = $CreateHardLink -or $Config.CreateHardLink
        }

        $TerraformCommand = $TerraformCommand.Trim()

        # If not explicit, sequence for laziness
        if ($Explicit) {
            Invoke-TerraformCommand -Command $TerraformCommand @TerraformCommandSplat
        }
        else {
            switch -Regex ($TerraformCommand) {
                '^plan|^apply' {
                    try {
                        Invoke-TerraformCommand -Command 'init' @TerraformCommandSplat
                    }
                    catch {
                        Clear-TerraformEnvironment
                        Invoke-TerraformCommand -Command 'init' @TerraformCommandSplat
                    }

                    Set-TerraformWorkspace -Workspace $Workspace -InitOnChange
                    Invoke-TerraformCommand -Command $TerraformCommand
                }
                '^destroy' {
                    try {
                        Invoke-TerraformCommand -Command 'init' @TerraformCommandSplat
                    }
                    catch {
                        Clear-TerraformEnvironment
                        Invoke-TerraformCommand -Command 'init' @TerraformCommandSplat
                    }

                    $Workspace = Set-TerraformWorkspace -Workspace $Workspace -InitOnChange -PassThru
                    Invoke-TerraformCommand -Command $TerraformCommand @TerraformCommandSplat
                    
                    if ($Workspace -ne 'default') {
                        Set-TerraformWorkspace -Workspace 'default'
                        Invoke-TerraformCommand -Command "workspace delete ${Workspace}" @TerraformCommandSplat
                    }
                }
                default { Invoke-TerraformCommand -Command $TerraformCommand @TerraformCommandSplat }
            }
        }
    }
    finally {
        Pop-Location -StackName 'terraposh' -ErrorAction Ignore
    }
}

function Invoke-TerraformCommand {
    param (
        [string]$Command,
        [string]$Version,
        [switch]$CreateHardLink
    )

    $TerraformBinary = Get-TerraformBinary -Version $Version
    $TerraformCommand = "${TerraformBinary} ${Command}"

    if ($CreateHardLink) {
        Set-TerraformBinaryHardLink -Value $TerraformBinary | Out-Null
    }

    Write-Verbose -Message $TerraformCommand
    Invoke-Expression -Command $TerraformCommand

    if ($LASTEXITCODE -notin @(0, 2)) {
        $ErrorMessage = "Terraform command failed with exit code: ${LASTEXITCODE}"
        throw ($ErrorMessage, $TerraformCommand -join "`n")
    }
}

function Merge-Hashtable {
    param (
        [hashtable]$HT1,
        [hashtable]$HT2
    )

    $TempHT = $HT1.Clone()

    foreach ($Key in $HT2.Keys) {
        if ($HT1.ContainsKey($Key)) {
            if ($HT1[$Key] -is [hashtable] -and $HT2[$Key] -is [hashtable]) {
                $TempHT[$Key] = Merge-Hashtable -HT1 $HT1[$Key] -HT2 $HT2[$Key]
                continue
            }
        }

        $TempHT[$Key] = $HT2[$Key]
    }

    return $TempHT
}

function Get-Config {
    param (
        [string]$File
    )

    # serach order/precedence (last wins)
    # - user profile ~/.terraposh.config.json
    # - git repo search (if in git repo), top of repo -> closest to working directory
    # - file param
    # - env var

    $SearchLoctaions = [ArrayList]::new()

    $UserProfileConfig = Join-Path -Path $HOME -ChildPath '.terraposh.config.json'
    $GitRepoConfigFiles = Get-GitRepoConfigFiles
    $EnvVarConfigFile = $env:TERRAPOSH_CONFIG_JSON

    $SearchLoctaions.Add($UserProfileConfig) | Out-Null
    $GitRepoConfigFiles | ForEach-Object { $SearchLoctaions.Add($_) | Out-Null } 
    $SearchLoctaions.Add($File) | Out-Null
    $SearchLoctaions.Add($EnvVarConfigFile) | Out-Null
    $SearchLoctaions = $SearchLoctaions | Get-Unique

    Write-Verbose "Search Locations:`n$($SearchLoctaions -join "`n")"

    $Config = @{}

    foreach ($SearchLoctaion in $SearchLoctaions) {
        if ([string]::IsNullOrWhiteSpace($SearchLoctaion)) {
            continue
        }

        if (-not (Test-Path -Path $SearchLoctaion)) {
            continue
        }

        $SearchLocationConfig = Get-Content -Path $SearchLoctaion -Raw | ConvertFrom-Json -AsHashtable
        $Config = Merge-Hashtable -HT1 $Config -HT2 $SearchLocationConfig
    }

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

function Test-GitRepo {
    $GitCommand = 'git rev-parse --is-inside-work-tree'
    $IsGitRepo = $true
    Invoke-Expression -Command $GitCommand *>&1 | Out-Null

    if ($LASTEXITCODE -ne 0) {
        $IsGitRepo = $false
    }

    return $IsGitRepo
}

function Get-GitTopLevel {
    $GitCommand = 'git rev-parse --show-toplevel'
    $GitTopLevel = Invoke-Expression -Command $GitCommand

    if ($LASTEXITCODE -ne 0) {
        $ErrorMessage = "Git command failed with non-zero exit code: ${LASTEXITCODE}"
        throw ($ErrorMessage, $GitCommand -join "`n")
    }

    return ($GitTopLevel | Resolve-Path).Path
}

function Get-GitRepoConfigFiles {
    $ConfigFiles = [ArrayList]::new()

    if (-not (Test-GitRepo)) {
        return $ConfigFiles
    }

    $GitTopLevel = Get-GitTopLevel
    $CurrentDirectory = ($PWD | Resolve-Path).Path
    $ConfigFileName = '.terraposh.config.json'

    do {
        $IsTopLevel = $CurrentDirectory -eq $GitTopLevel
        $ConfigFilePath = Join-Path -Path $CurrentDirectory -ChildPath $ConfigFileName

        if (Test-Path -Path $ConfigFilePath) {
            $ConfigFiles.Add($ConfigFilePath) | Out-Null
        }

        $CurrentDirectory = (Join-Path -Path $CurrentDirectory -ChildPath '..' | Resolve-Path).Path
    } until ($IsTopLevel)

    $ConfigFiles.Reverse()

    return [arraylist]$ConfigFiles
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
        [switch]$InitOnChange,
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
        $CurrentWorkspacesAvailable = Invoke-TerraformCommand -Command 'workspace list' | `
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | `
            ForEach-Object { $_.TrimStart('*').Trim() }
        Write-Verbose -Message "Current workspaces available: $($CurrentWorkspacesAvailable -join ', ')"

        if ($CurrentWorkspacesAvailable -ccontains $Workspace) {
            Write-Verbose -Message "${Workspace} already exists, selecting it"
            Invoke-TerraformCommand -Command "workspace select ${Workspace}" | Out-Null
        }
        else {
            Write-Verbose -Message "${Workspace} doesn't exist, creating it"
            Invoke-TerraformCommand -Command "workspace new ${Workspace}" | Out-Null
        }

        if ($InitOnChange) {
            Invoke-TerraformCommand -Command 'init'
        }
    }

    if ($PassThru) {
        return $Workspace
    }
}

function Get-LatestTerraformVersion {
    $Uri = 'https://checkpoint-api.hashicorp.com/v1/check/terraform'
    $Response = Invoke-RestMethod -Method Get -Uri $Uri

    return $Response.current_version
}

function Get-TerraformBinaryUri {
    param (
        [string]$Version
    )

    if ([string]::IsNullOrWhiteSpace($Version)) {
        $Version = Get-LatestTerraformVersion
    }

    $VersionEncoded = [HttpUtility]::UrlEncode($Version)
    $OSPart = [HttpUtility]::UrlEncode($IsWindows ? 'windows' : ($IsMacOS ? 'darwin' : 'linux'))
    $ArchPart = [HttpUtility]::UrlEncode(${env:PROCESSOR_ARCHITECTURE}?.ToLower()) ?? 'amd64'
    $Uri = "https://releases.hashicorp.com/terraform/${VersionEncoded}/terraform_${VersionEncoded}_${OSPart}_${ArchPart}.zip"

    return $Uri
}

function Get-TerraformBinary {
    param (
        [string]$Version
    )

    $Uri = Get-TerraformBinaryUri -Version $Version
    $FileName = $Uri -split '/' | Select-Object -Last 1
    $OutDirectory = Set-TerraformVendoredDirectory
    $OutFile = Join-Path -Path $OutDirectory -ChildPath $FileName

    if (-not (Test-Path -Path $OutFile)) {
        Invoke-RestMethod -Method Get -Uri $Uri -OutFile $OutFile | Out-Null
    }

    $ExpandDirectory = Join-Path -Path $OutDirectory -ChildPath $FileName.Trim('.zip')
    $BinaryFileName = Get-TerraformBinaryFileName
    $BinaryFile = Join-Path -Path $ExpandDirectory -ChildPath $BinaryFileName

    if (-not (Test-Path -Path $BinaryFile)) {
        Expand-Archive -Path $OutFile -DestinationPath $ExpandDirectory -Force | Out-Null
    }

    return $BinaryFile
}

function Get-TerraformBinaryFileName {
    return ($IsWindows ? 'terraform.exe' : 'terraform')
}

function Set-TerraformBinaryHardLink {
    param (
        [string]$Value
    )

    $VendoredDirectory = Set-TerraformVendoredDirectory
    $BinaryFileName = Get-TerraformBinaryFileName
    $HardLinkPath = Join-Path -Path $VendoredDirectory -ChildPath $BinaryFileName
    $HardLink = New-Item -ItemType HardLink -Path $HardLinkPath -Value $Value -Force

    return $HardLink.FullName
}

function Set-TerraformVendoredDirectory {
    if (-not (Test-Path -Path $HOME)) {
        Write-Error "Unable to access HOME directory: ${HOME}"
    }

    $Directory = Join-Path -Path $HOME -ChildPath '.terraposh' -AdditionalChildPath 'vendored'

    if (-not (Test-Path -Path $Directory)) {
        New-Item -Path $Directory -ItemType Directory -Force | Out-Null
    }

    return $Directory
}

# Helper functions
function Invoke-TerraposhPlan {
    [CmdletBinding()]
    param (
        [string]$TerraformCommand,
        [string]$ConfigFile,
        [string]$Directory,
        [string]$Workspace,
        [switch]$Explicit,
        [string]$Version,
        [switch]$CreateHardLink
    )

    $PSBoundParameters.Remove('TerraformCommand') | Out-Null
    Invoke-Terraposh -TerraformCommand "plan ${TerraformCommand}" @PSBoundParameters
}

function Invoke-TerraposhApply {
    [CmdletBinding()]
    param (
        [string]$TerraformCommand,
        [string]$ConfigFile,
        [string]$Directory,
        [string]$Workspace,
        [switch]$Explicit,
        [string]$Version,
        [switch]$CreateHardLink
    )

    $PSBoundParameters.Remove('TerraformCommand') | Out-Null
    Invoke-Terraposh -TerraformCommand "apply ${TerraformCommand}" @PSBoundParameters
}

function Invoke-TerraposhDestroy {
    [CmdletBinding()]
    param (
        [string]$TerraformCommand,
        [string]$ConfigFile,
        [string]$Directory,
        [string]$Workspace,
        [switch]$Explicit,
        [string]$Version,
        [switch]$CreateHardLink
    )

    $PSBoundParameters.Remove('TerraformCommand') | Out-Null
    Invoke-Terraposh -TerraformCommand "destroy ${TerraformCommand}" @PSBoundParameters
}

function Invoke-TerraposhDestroyAutoApprove {
    [CmdletBinding()]
    param (
        [string]$TerraformCommand,
        [string]$ConfigFile,
        [string]$Directory,
        [string]$Workspace,
        [switch]$Explicit,
        [string]$Version,
        [switch]$CreateHardLink
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
$ExportedFunctions = $ExportedMembers.Values | Out-String -Stream
$ExportedAliases = $ExportedMembers.Keys | Out-String -Stream
Export-ModuleMember -Function $ExportedFunctions -Alias $ExportedAliases
