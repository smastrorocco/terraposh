#Requires -Version 7.2

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
        [switch]$CreateHardLink,
        [switch]$SkipWorkspace
    )

    $script:VerifiedBinaries = @{}

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
        $CreateHardLink = $CreateHardLink -or $Config.CreateHardLink
        $SkipWorkspace = $SkipWorkspace -or $Config.SkipWorkspace

        $TerraformCommandSplat = @{
            Version        = [string]::IsNullOrWhiteSpace($Version) ? $Config.TerraformVersion : $Version
            CreateHardLink = $CreateHardLink
            SkipWorkspace  = $SkipWorkspace
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

                    Set-TerraformWorkspace -Workspace $Workspace -InitOnChange @TerraformCommandSplat
                    Invoke-TerraformCommand -Command $TerraformCommand @TerraformCommandSplat
                }
                '^destroy' {
                    try {
                        Invoke-TerraformCommand -Command 'init' @TerraformCommandSplat
                    }
                    catch {
                        Clear-TerraformEnvironment
                        Invoke-TerraformCommand -Command 'init' @TerraformCommandSplat
                    }

                    $Workspace = Set-TerraformWorkspace -Workspace $Workspace -InitOnChange -PassThru @TerraformCommandSplat
                    Invoke-TerraformCommand -Command $TerraformCommand @TerraformCommandSplat

                    if ($Workspace -ne 'default' -and (-not $SkipWorkspace)) {
                        Set-TerraformWorkspace -Workspace 'default' @TerraformCommandSplat
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

    # search order/precedence (last wins)
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
        [switch]$PassThru,
        [string]$Version,
        [switch]$CreateHardLink,
        [switch]$SkipWorkspace
    )

    # short circut if skip
    if ($SkipWorkspace) { return }

    if ([string]::IsNullOrWhiteSpace($Workspace)) {
        $Workspace = Get-TerraformWorkspaceName
    }

    # normalized workspace name: letters, numbers, hyphens, underscores
    # https://developer.hashicorp.com/terraform/cloud-docs/workspaces/create#create-a-workspace
    $Workspace = $Workspace -replace '[^a-zA-Z0-9\-_]', '_'

    $TerraformCommandSplat = @{
        Version        = $Version
        CreateHardLink = $CreateHardLink
    }
    
    Write-Verbose -Message "Workspace name: ${Workspace}"

    $CurrentWorkspace = Invoke-TerraformCommand -Command 'workspace show' @TerraformCommandSplat
    Write-Verbose -Message "Current workspace: ${CurrentWorkspace}"

    if ($Workspace -eq $CurrentWorkspace) {
        Write-Verbose -Message "Current workspace is already ${Workspace}"
    }
    else {
        $CurrentWorkspacesAvailable = Invoke-TerraformCommand -Command 'workspace list' @TerraformCommandSplat | `
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | `
            ForEach-Object { $_.TrimStart('*').Trim() }
        Write-Verbose -Message "Current workspaces available: $($CurrentWorkspacesAvailable -join ', ')"

        if ($CurrentWorkspacesAvailable -ccontains $Workspace) {
            Write-Verbose -Message "${Workspace} already exists, selecting it"
            Invoke-TerraformCommand -Command "workspace select ${Workspace}" @TerraformCommandSplat | Out-Null
        }
        else {
            Write-Verbose -Message "${Workspace} doesn't exist, creating it"
            Invoke-TerraformCommand -Command "workspace new ${Workspace}" @TerraformCommandSplat | Out-Null
        }

        if ($InitOnChange) {
            Invoke-TerraformCommand -Command 'init' @TerraformCommandSplat
        }
    }

    if ($PassThru) {
        return $Workspace
    }
}

function Get-LatestTerraformVersion {
    $Uri = 'https://checkpoint-api.hashicorp.com/v1/check/terraform'
    $Response = Invoke-RestMethod -Method Get -Uri $Uri
    $SemVer = $Response.current_version.TrimStart('v')

    return $SemVer
}

function Get-TerraformOS {
    return ($IsWindows ? 'windows' : ($IsMacOS ? 'darwin' : 'linux'))
}

function Get-TerraformArchitecture {
    param (
        [string]$Architecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
    )

    switch ($Architecture) {
        'X64' { return 'amd64' }
        'Arm64' { return 'arm64' }
        'X86' { return '386' }
        'Arm' { return 'arm' }
        default { throw "Unsupported architecture for Terraform: ${Architecture}" }
    }
}

function Get-TerraformRelease {
    param (
        [string]$Version,
        [string]$Architecture,
        [switch]$IsFallback
    )

    if ([string]::IsNullOrWhiteSpace($Version)) {
        Write-Warning -Message 'No Terraform version pinned (TerraformVersion / -Version), resolving latest release.'
        $Version = Get-LatestTerraformVersion
    }

    $Version = $Version.Trim().TrimStart('v')

    if ($Version -notmatch '^\d+\.\d+\.\d+(-[0-9A-Za-z.]+)?$') {
        throw "Invalid Terraform version: '${Version}'"
    }

    $OSPart = Get-TerraformOS
    $ArchPart = [string]::IsNullOrWhiteSpace($Architecture) ? (Get-TerraformArchitecture) : $Architecture
    $Platform = "${OSPart}_${ArchPart}"
    $FileName = "terraform_${Version}_${Platform}.zip"
    $BaseUri = "https://releases.hashicorp.com/terraform/${Version}"
    $OutDirectory = Set-TerraformVendoredDirectory
    $ExpandDirectory = Join-Path -Path $OutDirectory -ChildPath ([System.IO.Path]::GetFileNameWithoutExtension($FileName))

    return @{
        Version         = $Version
        Platform        = $Platform
        IsFallback      = [bool]$IsFallback
        FileName        = $FileName
        Uri             = "${BaseUri}/${FileName}"
        ChecksumsUri    = "${BaseUri}/terraform_${Version}_SHA256SUMS"
        SignatureUri    = "${BaseUri}/terraform_${Version}_SHA256SUMS.${HashiCorpKeyId}.sig"
        OutFile         = Join-Path -Path $OutDirectory -ChildPath $FileName
        ExpandDirectory = $ExpandDirectory
        BinaryFile      = Join-Path -Path $ExpandDirectory -ChildPath (Get-TerraformBinaryFileName)
        VerifiedFile    = Join-Path -Path $ExpandDirectory -ChildPath ($IsFallback ? '.terraposh-sha256-fallback' : '.terraposh-sha256')
    }
}

function Invoke-TerraformReleaseRequest {
    param (
        [string]$Uri,
        [string]$OutFile
    )

    $ParsedUri = [uri]$Uri

    if ($ParsedUri.Scheme -ne 'https' -or $ParsedUri.Host -ne 'releases.hashicorp.com') {
        throw "Refusing to download from untrusted location: ${Uri}"
    }

    if (-not [string]::IsNullOrWhiteSpace($OutFile)) {
        Invoke-WebRequest -Method Get -Uri $ParsedUri -MaximumRedirection 0 -OutFile $OutFile | Out-Null
        return
    }

    return , (Invoke-WebRequest -Method Get -Uri $ParsedUri -MaximumRedirection 0).RawContentStream.ToArray()
}

$HashiCorpKeyFile = Join-Path -Path $PSScriptRoot -ChildPath 'hashicorp.asc'
$HashiCorpKeyFingerprint = 'C874011F0AB405110D02105534365D9472D7468F'
$HashiCorpKeyId = '72D7468F'
$BouncyCastleAssembly = Join-Path -Path $PSScriptRoot -ChildPath 'lib' -AdditionalChildPath 'BouncyCastle.Cryptography.dll'

function Assert-TerraformChecksumsSignature {
    param (
        [byte[]]$ChecksumsBytes,
        [byte[]]$SignatureBytes,
        [string]$Source
    )

    if (-not ('Org.BouncyCastle.Bcpg.OpenPgp.PgpUtilities' -as [type])) {
        Add-Type -Path $BouncyCastleAssembly
    }

    try {
        $KeyStream = [System.IO.File]::OpenRead($HashiCorpKeyFile)

        try {
            $Keys = [Org.BouncyCastle.Bcpg.OpenPgp.PgpPublicKeyRingBundle]::new([Org.BouncyCastle.Bcpg.OpenPgp.PgpUtilities]::GetDecoderStream($KeyStream))
        }
        finally {
            $KeyStream.Dispose()
        }

        $SignatureStream = [Org.BouncyCastle.Bcpg.OpenPgp.PgpUtilities]::GetDecoderStream([System.IO.MemoryStream]::new($SignatureBytes))
        $Signatures = [Org.BouncyCastle.Bcpg.OpenPgp.PgpObjectFactory]::new($SignatureStream).NextPgpObject()
        $Signature = $Signatures -is [Org.BouncyCastle.Bcpg.OpenPgp.PgpSignatureList] -and $Signatures.Count -eq 1 ? $Signatures[0] : $null
        $Key = $Signature ? $Keys.GetPublicKey($Signature.KeyId) : $null
        $Valid = $false

        if ($Key) {
            $PrimaryKey = $Keys.GetPublicKeyRing($Signature.KeyId).GetPublicKey()
            $Signature.InitVerify($Key)
            $Signature.Update($ChecksumsBytes)
            $Valid = [System.Convert]::ToHexString($PrimaryKey.GetFingerprint()) -ceq $HashiCorpKeyFingerprint -and $Signature.Verify()
        }
    }
    catch {
        $Valid = $false
    }

    if (-not $Valid) {
        throw "PGP signature verification failed for ${Source}, refusing to use it."
    }

    Write-Verbose -Message "Verified ${Source} is signed by ${HashiCorpKeyFingerprint}"
}

function Get-TerraformReleaseChecksums {
    param (
        [hashtable]$Release
    )

    $ChecksumsBytes = Invoke-TerraformReleaseRequest -Uri $Release.ChecksumsUri
    $SignatureBytes = Invoke-TerraformReleaseRequest -Uri $Release.SignatureUri
    Assert-TerraformChecksumsSignature -ChecksumsBytes $ChecksumsBytes -SignatureBytes $SignatureBytes -Source $Release.ChecksumsUri

    $Checksums = @{}

    foreach ($Line in ([System.Text.Encoding]::UTF8.GetString($ChecksumsBytes) -split "`n")) {
        $Hash, $FileName = $Line.Trim() -split '\s+', 2

        if ([string]::IsNullOrWhiteSpace($FileName)) {
            continue
        }

        if ($Hash -notmatch '^[0-9a-fA-F]{64}$' -or $Checksums.ContainsKey($FileName)) {
            throw "Malformed SHA256SUMS entry in $($Release.ChecksumsUri): ${Line}"
        }

        $Checksums[$FileName] = $Hash.ToLower()
    }

    return $Checksums
}

function Get-FileSha256 {
    param (
        [string]$Path
    )

    return (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLower()
}

$VerifiedBinaries = @{}

function Get-TerraformCachedBinaryStatus {
    param (
        [string]$BinaryFile,
        [string]$VerifiedFile
    )

    if (-not (Test-Path -Path $BinaryFile -PathType Leaf) -or -not (Test-Path -Path $VerifiedFile -PathType Leaf)) {
        return 'Missing'
    }

    $BinaryHash = "$(Get-Content -Path $VerifiedFile -Raw -Force)".Trim()

    if ($BinaryHash -cnotmatch '^[0-9a-f]{64}$') {
        return 'Missing'
    }

    if ($script:VerifiedBinaries[$BinaryFile] -ceq $BinaryHash) {
        return 'Valid'
    }

    if ((Get-FileSha256 -Path $BinaryFile) -cne $BinaryHash) {
        return 'Modified'
    }

    $script:VerifiedBinaries[$BinaryFile] = $BinaryHash

    return 'Valid'
}

function Wait-TerraposhLock {
    param (
        [string]$Path,
        [int]$TimeoutSeconds = 600
    )

    $Deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)

    while ($true) {
        try {
            return [System.IO.File]::Open($Path, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        }
        catch [System.IO.IOException] {
            $Exception = $_.Exception.InnerException ?? $_.Exception

            if ($Exception.GetType() -ne [System.IO.IOException]) {
                throw
            }

            if ([DateTime]::UtcNow -ge $Deadline) {
                throw "Timed out after ${TimeoutSeconds}s waiting for another terraposh process to release ${Path}"
            }

            Start-Sleep -Milliseconds 250
        }
    }
}

function Expand-TerraformArchive {
    param (
        [hashtable]$Release
    )

    Remove-Item -Path $Release.ExpandDirectory -Recurse -Force -ErrorAction Ignore
    Expand-Archive -Path $Release.OutFile -DestinationPath $Release.ExpandDirectory -Force | Out-Null
    $BinaryHash = Get-FileSha256 -Path $Release.BinaryFile
    Set-Content -Path $Release.VerifiedFile -Value $BinaryHash -NoNewline
    $script:VerifiedBinaries[$Release.BinaryFile] = $BinaryHash
}

function Get-TerraformBinary {
    param (
        [string]$Version
    )

    $Candidates = @(Get-TerraformRelease -Version $Version)
    $NativeRelease = $Candidates[0]

    if ((Get-TerraformArchitecture) -eq 'arm64' -and (Get-TerraformOS) -in @('darwin', 'windows')) {
        $Candidates += Get-TerraformRelease -Version $NativeRelease.Version -Architecture 'amd64' -IsFallback
    }

    foreach ($Candidate in $Candidates) {
        $Status = Get-TerraformCachedBinaryStatus -BinaryFile $Candidate.BinaryFile -VerifiedFile $Candidate.VerifiedFile

        if ($Status -eq 'Valid') {
            return $Candidate.BinaryFile
        }

        if ($Status -eq 'Modified') {
            Write-Warning -Message "Cached Terraform binary failed SHA-256 verification, re-extracting: $($Candidate.BinaryFile)"
        }
    }

    $Checksums = Get-TerraformReleaseChecksums -Release $NativeRelease
    $Release = $Candidates | Where-Object { $Checksums.ContainsKey($_.FileName) } | Select-Object -First 1

    if (-not $Release) {
        throw "Terraform $($NativeRelease.Version) has no published build for $($NativeRelease.Platform) in $($NativeRelease.ChecksumsUri)"
    }

    if ($Release.IsFallback) {
        $Emulation = (Get-TerraformOS) -eq 'darwin' ? 'Rosetta 2' : 'x64 emulation'
        Write-Warning -Message "Terraform $($Release.Version) has no $($NativeRelease.Platform) build, using $($Release.Platform) under ${Emulation}."
    }

    $ExpectedHash = $Checksums[$Release.FileName]
    $Lock = Wait-TerraposhLock -Path "$($Release.OutFile).lock"

    try {
        if ((Get-TerraformCachedBinaryStatus -BinaryFile $Release.BinaryFile -VerifiedFile $Release.VerifiedFile) -eq 'Valid') {
            return $Release.BinaryFile
        }

        if ((Test-Path -Path $Release.OutFile) -and (Get-FileSha256 -Path $Release.OutFile) -cne $ExpectedHash) {
            Write-Warning -Message "Cached archive failed SHA-256 verification, re-downloading: $($Release.OutFile)"
            Remove-Item -Path $Release.OutFile -Force
        }

        if (-not (Test-Path -Path $Release.OutFile)) {
            Invoke-TerraformReleaseRequest -Uri $Release.Uri -OutFile $Release.OutFile

            if ((Get-FileSha256 -Path $Release.OutFile) -cne $ExpectedHash) {
                Remove-Item -Path $Release.OutFile -Force
                throw "SHA-256 checksum mismatch for $($Release.Uri), refusing to use it."
            }
        }

        Expand-TerraformArchive -Release $Release

        return $Release.BinaryFile
    }
    finally {
        $Lock.Dispose()
    }
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

    try {
        New-Item -ItemType HardLink -Path $HardLinkPath -Value $Value -Force | Out-Null
    }
    catch {
        Write-Warning "Failed to create HardLink: ${HardLinkPath}"
    }

    return $HardLinkPath
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
        [switch]$CreateHardLink,
        [switch]$SkipWorkspace
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
        [switch]$CreateHardLink,
        [switch]$SkipWorkspace
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
        [switch]$CreateHardLink,
        [switch]$SkipWorkspace
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
        [switch]$CreateHardLink,
        [switch]$SkipWorkspace
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
