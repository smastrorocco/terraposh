#Requires -Version 7.2
#Requires -Modules @{ ModuleName = 'Pester'; RequiredVersion = '6.2.0' }

BeforeDiscovery {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'terraposh.psd1') -Force
}

InModuleScope terraposh {
    Describe 'Get-TerraformArchitecture' {
        It 'maps <Architecture> to <Expected>' -TestCases @(
            @{ Architecture = 'X64'; Expected = 'amd64' }
            @{ Architecture = 'Arm64'; Expected = 'arm64' }
            @{ Architecture = 'X86'; Expected = '386' }
            @{ Architecture = 'Arm'; Expected = 'arm' }
        ) {
            Get-TerraformArchitecture -Architecture $Architecture | Should -Be $Expected
        }

        It 'throws on an unsupported architecture' {
            { Get-TerraformArchitecture -Architecture 'S390x' } | Should -Throw '*Unsupported architecture*'
        }

        It 'detects the current OS architecture' {
            Get-TerraformArchitecture | Should -BeIn @('amd64', 'arm64', '386', 'arm')
        }
    }

    Describe 'Get-TerraformRelease' {
        BeforeEach {
            Mock Set-TerraformVendoredDirectory { Join-Path -Path $TestDrive -ChildPath 'vendored' }
            Mock Get-TerraformOS { 'linux' }
            Mock Get-TerraformArchitecture { 'amd64' }
        }

        It 'builds release URIs on releases.hashicorp.com' {
            $Release = Get-TerraformRelease -Version '1.9.8'

            $Release.Version | Should -Be '1.9.8'
            $Release.Platform | Should -Be 'linux_amd64'
            $Release.FileName | Should -Be 'terraform_1.9.8_linux_amd64.zip'
            $Release.Uri | Should -Be 'https://releases.hashicorp.com/terraform/1.9.8/terraform_1.9.8_linux_amd64.zip'
            $Release.ChecksumsUri | Should -Be 'https://releases.hashicorp.com/terraform/1.9.8/terraform_1.9.8_SHA256SUMS'
            $Release.IsFallback | Should -BeFalse
            Split-Path -Leaf $Release.VerifiedFile | Should -Be '.terraposh-sha256'
        }

        It 'trims a leading v and whitespace' {
            (Get-TerraformRelease -Version ' v1.9.8 ').Version | Should -Be '1.9.8'
        }

        It 'accepts pre-release versions' {
            (Get-TerraformRelease -Version '1.10.0-beta1').Version | Should -Be '1.10.0-beta1'
        }

        It 'uses an explicit architecture and a separate marker for fallback builds' {
            $Release = Get-TerraformRelease -Version '1.0.1' -Architecture 'amd64' -IsFallback

            $Release.Platform | Should -Be 'linux_amd64'
            $Release.IsFallback | Should -BeTrue
            Split-Path -Leaf $Release.VerifiedFile | Should -Be '.terraposh-sha256-fallback'
        }

        It 'rejects invalid version <Version>' -TestCases @(
            @{ Version = '1.9.8/../../evil' }
            @{ Version = '1.9' }
            @{ Version = 'latest' }
            @{ Version = '1.9.8?x=1' }
            @{ Version = '1.9.8-beta/1' }
        ) {
            { Get-TerraformRelease -Version $Version } | Should -Throw '*Invalid Terraform version*'
        }

        It 'warns and resolves the latest version when none is pinned' {
            Mock Write-Warning {}
            Mock Get-LatestTerraformVersion { '1.16.5' }

            (Get-TerraformRelease -Version '').Version | Should -Be '1.16.5'
            Should -Invoke Write-Warning -Exactly -Times 1 -ParameterFilter { $Message -like '*No Terraform version pinned*' }
        }
    }

    Describe 'Invoke-TerraformReleaseRequest' {
        BeforeEach {
            Mock Invoke-WebRequest {}
        }

        It 'refuses <Uri>' -TestCases @(
            @{ Uri = 'http://releases.hashicorp.com/terraform/1.9.8/terraform_1.9.8_SHA256SUMS' }
            @{ Uri = 'https://example.com/terraform_1.9.8_SHA256SUMS' }
            @{ Uri = 'https://releases.hashicorp.com.evil.example/terraform_1.9.8_SHA256SUMS' }
            @{ Uri = 'ftp://releases.hashicorp.com/terraform_1.9.8_SHA256SUMS' }
        ) {
            { Invoke-TerraformReleaseRequest -Uri $Uri -OutFile 'out' } | Should -Throw '*Refusing to download*'
            Should -Invoke Invoke-WebRequest -Times 0
        }

        It 'returns the response bytes without OutFile' {
            Mock Invoke-WebRequest { [pscustomobject]@{ RawContentStream = [System.IO.MemoryStream]::new([byte[]](1, 2, 3)) } }

            $Bytes = Invoke-TerraformReleaseRequest -Uri 'https://releases.hashicorp.com/terraform/1.9.8/terraform_1.9.8_SHA256SUMS'

            $Bytes -is [byte[]] | Should -BeTrue
            $Bytes | Should -Be @(1, 2, 3)
            Should -Invoke Invoke-WebRequest -Exactly -Times 1 -ParameterFilter { $MaximumRedirection -eq 0 -and -not $OutFile }
        }

        It 'downloads over HTTPS without following redirects' {
            Invoke-TerraformReleaseRequest -Uri 'https://releases.hashicorp.com/terraform/1.9.8/terraform_1.9.8_SHA256SUMS' -OutFile 'out'

            Should -Invoke Invoke-WebRequest -Exactly -Times 1 -ParameterFilter {
                $MaximumRedirection -eq 0 -and $OutFile -eq 'out' -and
                $Uri.AbsoluteUri -eq 'https://releases.hashicorp.com/terraform/1.9.8/terraform_1.9.8_SHA256SUMS'
            }
        }
    }

    Describe 'Get-TerraformReleaseChecksums' {
        BeforeAll {
            $Release = @{
                ChecksumsUri = 'https://releases.hashicorp.com/terraform/1.9.8/terraform_1.9.8_SHA256SUMS'
                SignatureUri = 'https://releases.hashicorp.com/terraform/1.9.8/terraform_1.9.8_SHA256SUMS.72D7468F.sig'
            }
            $HashA = 'A' * 64
            $HashB = 'b' * 64
        }

        BeforeEach {
            $script:Sums = "${HashA}  terraform_1.9.8_linux_amd64.zip`n${HashB}  terraform_1.9.8_darwin_arm64.zip`n`n"
            Mock Invoke-TerraformReleaseRequest { , [System.Text.Encoding]::UTF8.GetBytes($script:Sums) } -ParameterFilter { $Uri -like '*_SHA256SUMS' }
            Mock Invoke-TerraformReleaseRequest { , [byte[]](9, 9, 9) } -ParameterFilter { $Uri -like '*.sig' }
            Mock Assert-TerraformChecksumsSignature {}
        }

        It 'parses entries and normalises hashes to lowercase' {
            $Checksums = Get-TerraformReleaseChecksums -Release $Release

            $Checksums.Count | Should -Be 2
            $Checksums['terraform_1.9.8_linux_amd64.zip'] | Should -Be ('a' * 64)
            $Checksums['terraform_1.9.8_darwin_arm64.zip'] | Should -Be $HashB
        }

        It 'handles CRLF line endings' {
            $script:Sums = "${HashA}  terraform_1.9.8_linux_amd64.zip`r`n"

            (Get-TerraformReleaseChecksums -Release $Release).Keys | Should -Be 'terraform_1.9.8_linux_amd64.zip'
        }

        It 'throws on a malformed hash' {
            $script:Sums = 'abc123  terraform_1.9.8_linux_amd64.zip'

            { Get-TerraformReleaseChecksums -Release $Release } | Should -Throw '*Malformed SHA256SUMS entry*'
        }

        It 'throws on duplicate entries' {
            $script:Sums = "${HashA}  terraform_1.9.8_linux_amd64.zip`n${HashB}  terraform_1.9.8_linux_amd64.zip"

            { Get-TerraformReleaseChecksums -Release $Release } | Should -Throw '*Malformed SHA256SUMS entry*'
        }

        It 'verifies the downloaded checksums against the downloaded signature' {
            Mock Assert-TerraformChecksumsSignature {
                [System.Text.Encoding]::UTF8.GetString($ChecksumsBytes) | Should -BeExactly $script:Sums
                $SignatureBytes | Should -Be @(9, 9, 9)
                $Source | Should -Be 'https://releases.hashicorp.com/terraform/1.9.8/terraform_1.9.8_SHA256SUMS'
            }

            Get-TerraformReleaseChecksums -Release $Release | Out-Null
            Should -Invoke Assert-TerraformChecksumsSignature -Exactly -Times 1
        }

        It 'checks the signature before parsing' {
            $script:Sums = 'not a checksum file'
            Mock Assert-TerraformChecksumsSignature { throw 'PGP signature verification failed' }

            { Get-TerraformReleaseChecksums -Release $Release } | Should -Throw '*PGP signature verification failed*'
        }
    }

    Describe 'Assert-TerraformChecksumsSignature' {
        BeforeAll {
            $Fixtures = Join-Path -Path $PSScriptRoot -ChildPath 'fixtures'
            $ChecksumsBytes = [System.IO.File]::ReadAllBytes((Join-Path -Path $Fixtures -ChildPath 'terraform_1.9.8_SHA256SUMS'))
            $SignatureBytes = [System.IO.File]::ReadAllBytes((Join-Path -Path $Fixtures -ChildPath 'terraform_1.9.8_SHA256SUMS.72D7468F.sig'))
            $OtherReleaseSignatureBytes = [System.IO.File]::ReadAllBytes((Join-Path -Path $Fixtures -ChildPath 'terraform_0.11.15_SHA256SUMS.72D7468F.sig'))

            if (-not ('Org.BouncyCastle.Bcpg.OpenPgp.PgpUtilities' -as [type])) {
                Add-Type -Path $BouncyCastleAssembly
            }
        }

        It 'accepts HashiCorp''s genuine signature' {
            { Assert-TerraformChecksumsSignature -ChecksumsBytes $ChecksumsBytes -SignatureBytes $SignatureBytes -Source 'SHA256SUMS' } | Should -Not -Throw
        }

        It 'rejects a tampered checksum file' {
            $Tampered = [byte[]]$ChecksumsBytes.Clone()
            $Tampered[0] = $Tampered[0] -bxor 0x01

            { Assert-TerraformChecksumsSignature -ChecksumsBytes $Tampered -SignatureBytes $SignatureBytes -Source 'SHA256SUMS' } | Should -Throw 'PGP signature verification failed for SHA256SUMS*'
        }

        It 'rejects the genuine signature of a different release' {
            { Assert-TerraformChecksumsSignature -ChecksumsBytes $ChecksumsBytes -SignatureBytes $OtherReleaseSignatureBytes -Source 'SHA256SUMS' } | Should -Throw 'PGP signature verification failed*'
        }

        It 'rejects <Case>' -TestCases @(
            @{ Case = 'garbage'; Bytes = [byte[]](1, 2, 3) }
            @{ Case = 'an empty signature'; Bytes = [byte[]]@() }
        ) {
            { Assert-TerraformChecksumsSignature -ChecksumsBytes $ChecksumsBytes -SignatureBytes $Bytes -Source 'SHA256SUMS' } | Should -Throw 'PGP signature verification failed*'
        }

        It 'rejects a signature whose key is not the pinned HashiCorp key' {
            $Pinned = $script:HashiCorpKeyFingerprint
            $script:HashiCorpKeyFingerprint = '0' * 40

            try {
                { Assert-TerraformChecksumsSignature -ChecksumsBytes $ChecksumsBytes -SignatureBytes $SignatureBytes -Source 'SHA256SUMS' } | Should -Throw 'PGP signature verification failed*'
            }
            finally {
                $script:HashiCorpKeyFingerprint = $Pinned
            }
        }

        It 'bundles the HashiCorp key with the pinned fingerprint' {
            $KeyStream = [System.IO.File]::OpenRead($HashiCorpKeyFile)

            try {
                $Keys = [Org.BouncyCastle.Bcpg.OpenPgp.PgpPublicKeyRingBundle]::new([Org.BouncyCastle.Bcpg.OpenPgp.PgpUtilities]::GetDecoderStream($KeyStream))
            }
            finally {
                $KeyStream.Dispose()
            }

            $Fingerprints = @($Keys.GetKeyRings() | ForEach-Object { [System.Convert]::ToHexString($_.GetPublicKey().GetFingerprint()) })
            $Fingerprints | Should -Be @($HashiCorpKeyFingerprint)
            $HashiCorpKeyFingerprint | Should -BeLike "*${HashiCorpKeyId}"
        }
    }

    Describe 'Get-TerraformCachedBinaryStatus' {
        BeforeEach {
            $script:VerifiedBinaries = @{}
            $Directory = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid())
            New-Item -Path $Directory -ItemType Directory | Out-Null
            $Binary = Join-Path -Path $Directory -ChildPath 'terraform'
            $Marker = Join-Path -Path $Directory -ChildPath '.terraposh-sha256'
            Set-Content -Path $Binary -Value 'terraform' -NoNewline
            $BinaryHash = (Get-FileHash -Path $Binary -Algorithm SHA256).Hash.ToLower()
        }

        It 'is Valid when the binary matches the recorded hash' {
            Set-Content -Path $Marker -Value $BinaryHash -NoNewline

            Get-TerraformCachedBinaryStatus -BinaryFile $Binary -VerifiedFile $Marker | Should -Be 'Valid'
        }

        It 'is Modified when the binary no longer matches the recorded hash' {
            Set-Content -Path $Marker -Value $BinaryHash -NoNewline
            Set-Content -Path $Binary -Value 'tampered' -NoNewline

            Get-TerraformCachedBinaryStatus -BinaryFile $Binary -VerifiedFile $Marker | Should -Be 'Modified'
        }

        It 'is Missing for <Case>' -TestCases @(
            @{ Case = 'an older multi-line marker'; Content = "$('a' * 64)`nsignature=Verified`nbinary=BINARY" }
            @{ Case = 'a malformed hash'; Content = 'xyz' }
            @{ Case = 'an uppercase hash'; Content = 'UPPER' }
            @{ Case = 'an empty marker'; Content = '' }
        ) {
            Set-Content -Path $Marker -Value ($Content -replace 'BINARY', $BinaryHash -replace 'UPPER', $BinaryHash.ToUpper()) -NoNewline

            Get-TerraformCachedBinaryStatus -BinaryFile $Binary -VerifiedFile $Marker | Should -Be 'Missing'
        }

        It 'is Missing without a marker or without a binary' {
            Get-TerraformCachedBinaryStatus -BinaryFile $Binary -VerifiedFile $Marker | Should -Be 'Missing'

            Set-Content -Path $Marker -Value $BinaryHash -NoNewline
            Remove-Item -Path $Binary
            Get-TerraformCachedBinaryStatus -BinaryFile $Binary -VerifiedFile $Marker | Should -Be 'Missing'
        }

        It 'hashes a binary only once until the cache is reset' {
            Set-Content -Path $Marker -Value $BinaryHash -NoNewline
            Get-TerraformCachedBinaryStatus -BinaryFile $Binary -VerifiedFile $Marker | Should -Be 'Valid'
            Set-Content -Path $Binary -Value 'tampered' -NoNewline

            Get-TerraformCachedBinaryStatus -BinaryFile $Binary -VerifiedFile $Marker | Should -Be 'Valid'
            $script:VerifiedBinaries = @{}
            Get-TerraformCachedBinaryStatus -BinaryFile $Binary -VerifiedFile $Marker | Should -Be 'Modified'
        }
    }

    Describe 'Wait-TerraposhLock' {
        BeforeEach {
            $LockFile = Join-Path -Path $TestDrive -ChildPath "$([guid]::NewGuid()).lock"
        }

        It 'acquires an exclusive lock' {
            $Lock = Wait-TerraposhLock -Path $LockFile

            try {
                { [System.IO.File]::Open($LockFile, 'OpenOrCreate', 'ReadWrite', 'None').Dispose() } | Should -Throw
            }
            finally {
                $Lock.Dispose()
            }
        }

        It 'fails immediately on errors other than lock contention' {
            $Missing = Join-Path -Path $TestDrive -ChildPath 'missing' -AdditionalChildPath 'x.lock'
            $Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

            { Wait-TerraposhLock -Path $Missing -TimeoutSeconds 30 } | Should -Throw '*Could not find a part of the path*'
            $Stopwatch.Elapsed.TotalSeconds | Should -BeLessThan 5
        }

        It 'times out while the lock is held' {
            $Held = [System.IO.File]::Open($LockFile, 'OpenOrCreate', 'ReadWrite', 'None')

            try {
                { Wait-TerraposhLock -Path $LockFile -TimeoutSeconds 1 } | Should -Throw '*Timed out after 1s*'
            }
            finally {
                $Held.Dispose()
            }
        }

        It 'waits for another process to release the lock' {
            $Ready = "${LockFile}.ready"
            $Holder = Start-Process -FilePath (Get-Process -Id $PID).Path -PassThru -NoNewWindow -ArgumentList @(
                '-NoProfile', '-Command',
                "`$f = [System.IO.File]::Open('${LockFile}', 'OpenOrCreate', 'ReadWrite', 'None'); New-Item -Path '${Ready}' | Out-Null; Start-Sleep -Seconds 2; `$f.Dispose()"
            )

            try {
                $Deadline = [DateTime]::UtcNow.AddSeconds(30)
                while (-not (Test-Path -Path $Ready) -and [DateTime]::UtcNow -lt $Deadline) { Start-Sleep -Milliseconds 50 }
                Test-Path -Path $Ready | Should -BeTrue

                $Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
                $Lock = Wait-TerraposhLock -Path $LockFile -TimeoutSeconds 30
                $Stopwatch.Stop()
                $Lock.Dispose()

                $Stopwatch.Elapsed.TotalSeconds | Should -BeGreaterThan 1
            }
            finally {
                $Holder.WaitForExit()
            }
        }
    }

    Describe 'Get-FileSha256' {
        It 'returns the lowercase SHA-256 of a file' {
            $File = Join-Path -Path $TestDrive -ChildPath 'file.txt'
            Set-Content -Path $File -Value 'terraposh' -NoNewline

            Get-FileSha256 -Path $File | Should -BeExactly 'f5c00f445df8e43bb50f7816a6658bedbc21590bc07cf829b632fa5e4d83fda8'
        }
    }

    Describe 'Get-TerraformBinary' {
        BeforeAll {
            $BinaryFileName = Get-TerraformBinaryFileName
            $SourceDirectory = Join-Path -Path $TestDrive -ChildPath 'source'
            New-Item -Path $SourceDirectory -ItemType Directory | Out-Null
            Set-Content -Path (Join-Path -Path $SourceDirectory -ChildPath $BinaryFileName) -Value 'genuine terraform' -NoNewline
            $FakeArchive = Join-Path -Path $TestDrive -ChildPath 'terraform.zip'
            Compress-Archive -Path (Join-Path -Path $SourceDirectory -ChildPath $BinaryFileName) -DestinationPath $FakeArchive
            $FakeHash = (Get-FileHash -Path $FakeArchive -Algorithm SHA256).Hash.ToLower()
            $GenuineBinaryHash = (Get-FileHash -Path (Join-Path -Path $SourceDirectory -ChildPath $BinaryFileName) -Algorithm SHA256).Hash.ToLower()

            function New-CachedBinary([string]$Platform, [string]$Content, [string]$MarkerName = '.terraposh-sha256') {
                $Directory = Get-VendoredPath "terraform_1.9.8_${Platform}"
                New-Item -Path $Directory -ItemType Directory -Force | Out-Null
                $Binary = Join-Path -Path $Directory -ChildPath $BinaryFileName
                Set-Content -Path $Binary -Value $Content -NoNewline
                $Hash = (Get-FileHash -Path $Binary -Algorithm SHA256).Hash.ToLower()
                Set-Content -Path (Join-Path -Path $Directory -ChildPath $MarkerName) -Value $Hash -NoNewline
                return $Binary
            }

            function Get-VendoredPath([string]$ChildPath) {
                (Join-Path -Path $TestDrive -ChildPath 'vendored' -AdditionalChildPath $ChildPath) -replace '/', [System.IO.Path]::DirectorySeparatorChar
            }
        }

        BeforeEach {
            $script:VerifiedBinaries = @{}
            $VendoredDirectory = Join-Path -Path $TestDrive -ChildPath 'vendored'
            Remove-Item -Path $VendoredDirectory -Recurse -Force -ErrorAction Ignore
            New-Item -Path $VendoredDirectory -ItemType Directory | Out-Null

            $script:PublishedChecksums = @{
                'terraform_1.9.8_darwin_arm64.zip' = $FakeHash
                'terraform_1.9.8_darwin_amd64.zip' = $FakeHash
            }

            Mock Set-TerraformVendoredDirectory { Join-Path -Path $TestDrive -ChildPath 'vendored' }
            Mock Get-TerraformOS { 'darwin' }
            Mock Get-TerraformArchitecture { 'arm64' }
            Mock Write-Warning {}
            Mock Get-TerraformReleaseChecksums { $script:PublishedChecksums }
            Mock Invoke-TerraformReleaseRequest { Copy-Item -Path $FakeArchive -Destination $OutFile }
        }

        It 'downloads, verifies and extracts the native build' {
            $Binary = Get-TerraformBinary -Version '1.9.8'

            $Binary | Should -Be (Get-VendoredPath "terraform_1.9.8_darwin_arm64/${BinaryFileName}")
            Get-Content -Path $Binary -Raw | Should -Be 'genuine terraform'
            Get-Content -Path (Get-VendoredPath 'terraform_1.9.8_darwin_arm64/.terraposh-sha256') -Force | Should -Be $GenuineBinaryHash
            Should -Invoke Invoke-TerraformReleaseRequest -Exactly -Times 1 -ParameterFilter {
                $Uri -eq 'https://releases.hashicorp.com/terraform/1.9.8/terraform_1.9.8_darwin_arm64.zip'
            }
            Should -Invoke Write-Warning -Times 0
        }

        It 'reuses a verified binary without network access' {
            Get-TerraformBinary -Version '1.9.8' | Out-Null
            $Binary = Get-TerraformBinary -Version '1.9.8'

            Get-Content -Path $Binary -Raw | Should -Be 'genuine terraform'
            Should -Invoke Get-TerraformReleaseChecksums -Exactly -Times 1
            Should -Invoke Invoke-TerraformReleaseRequest -Exactly -Times 1
        }

        It 'refuses a download that fails checksum verification and leaves nothing behind' {
            $script:PublishedChecksums['terraform_1.9.8_darwin_arm64.zip'] = '0' * 64

            { Get-TerraformBinary -Version '1.9.8' } | Should -Throw '*SHA-256 checksum mismatch*'
            Get-ChildItem -Path (Get-VendoredPath '') -Force -Exclude '*.lock' | Should -BeNullOrEmpty
        }

        It 're-downloads a tampered cached archive' {
            Copy-Item -Path $FakeArchive -Destination (Get-VendoredPath 'terraform_1.9.8_darwin_arm64.zip')
            Add-Content -Path (Get-VendoredPath 'terraform_1.9.8_darwin_arm64.zip') -Value 'tampered'

            $Binary = Get-TerraformBinary -Version '1.9.8'

            Get-Content -Path $Binary -Raw | Should -Be 'genuine terraform'
            Get-FileSha256 -Path (Get-VendoredPath 'terraform_1.9.8_darwin_arm64.zip') | Should -Be $FakeHash
            Should -Invoke Write-Warning -Exactly -Times 1 -ParameterFilter { $Message -like '*failed SHA-256 verification*' }
            Should -Invoke Invoke-TerraformReleaseRequest -Exactly -Times 1
        }

        It 'reuses a cached archive that passes verification without downloading it again' {
            Copy-Item -Path $FakeArchive -Destination (Get-VendoredPath 'terraform_1.9.8_darwin_arm64.zip')

            Get-Content -Path (Get-TerraformBinary -Version '1.9.8') -Raw | Should -Be 'genuine terraform'
            Should -Invoke Invoke-TerraformReleaseRequest -Times 0
        }

        It 'does not trust a previously extracted binary without a verification marker' {
            $LegacyDirectory = Get-VendoredPath 'terraform_1.9.8_darwin_arm64'
            New-Item -Path $LegacyDirectory -ItemType Directory | Out-Null
            Set-Content -Path (Join-Path -Path $LegacyDirectory -ChildPath $BinaryFileName) -Value 'unverified'
            Set-Content -Path (Join-Path -Path $LegacyDirectory -ChildPath 'stale.txt') -Value 'stale'

            $Binary = Get-TerraformBinary -Version '1.9.8'

            Get-Content -Path $Binary -Raw | Should -Be 'genuine terraform'
            Test-Path -Path (Join-Path -Path $LegacyDirectory -ChildPath 'stale.txt') | Should -BeFalse
        }

        It 'throws when the checksum file has no entry for the build' {
            $script:PublishedChecksums = @{ 'terraform_1.9.8_linux_amd64.zip' = $FakeHash }
            Mock Get-TerraformOS { 'linux' }

            { Get-TerraformBinary -Version '1.9.8' } | Should -Throw '*no published build for linux_arm64*'
            Should -Invoke Invoke-TerraformReleaseRequest -Times 0
        }

        Context 'signature verification' {
            It 'does not download when the checksum signature fails' {
                Mock Get-TerraformReleaseChecksums { throw 'PGP signature verification failed' }

                { Get-TerraformBinary -Version '1.9.8' } | Should -Throw '*PGP signature verification failed*'
                Should -Invoke Invoke-TerraformReleaseRequest -Times 0
                Get-ChildItem -Path (Get-VendoredPath '') -Force -Exclude '*.lock' | Should -BeNullOrEmpty
            }

            It 're-verifies a binary cached <Case>' -TestCases @(
                @{ Case = 'before signature checks existed'; Content = 'HASH' }
                @{ Case = 'with an Unverified signature'; Content = "HASH`nsignature=Unverified" }
                @{ Case = 'with signatures Off'; Content = "HASH`nsignature=Off" }
                @{ Case = 'with the previous three-line marker'; Content = "HASH`nsignature=Verified`nbinary=HASH" }
            ) {
                $Directory = Get-VendoredPath 'terraform_1.9.8_darwin_arm64'
                New-Item -Path $Directory -ItemType Directory | Out-Null
                Set-Content -Path (Join-Path -Path $Directory -ChildPath $BinaryFileName) -Value 'legacy'
                Set-Content -Path (Join-Path -Path $Directory -ChildPath '.terraposh-sha256') -Value ($Content -replace 'HASH', $FakeHash) -NoNewline

                Get-Content -Path (Get-TerraformBinary -Version '1.9.8') -Raw | Should -Be 'genuine terraform'
                Should -Invoke Get-TerraformReleaseChecksums -Exactly -Times 1
                Get-Content -Path (Get-VendoredPath 'terraform_1.9.8_darwin_arm64/.terraposh-sha256') -Force | Should -Be $GenuineBinaryHash
            }
        }

        Context 'cached binary integrity' {
            It 'reuses a cached binary that matches its recorded hash' {
                $Binary = New-CachedBinary 'darwin_arm64' 'cached terraform'

                Get-TerraformBinary -Version '1.9.8' | Should -Be $Binary
                Should -Invoke Get-TerraformReleaseChecksums -Times 0
            }

            It 'warns and re-extracts a cached binary that was modified' {
                $Binary = New-CachedBinary 'darwin_arm64' 'cached terraform'
                Copy-Item -Path $FakeArchive -Destination (Get-VendoredPath 'terraform_1.9.8_darwin_arm64.zip')
                Set-Content -Path $Binary -Value 'tampered' -NoNewline

                Get-Content -Path (Get-TerraformBinary -Version '1.9.8') -Raw | Should -Be 'genuine terraform'
                Should -Invoke Write-Warning -Exactly -Times 1 -ParameterFilter { $Message -like 'Cached Terraform binary failed SHA-256 verification*' }
                Should -Invoke Invoke-TerraformReleaseRequest -Times 0
                Get-Content -Path (Get-VendoredPath 'terraform_1.9.8_darwin_arm64/.terraposh-sha256') -Force | Should -Be $GenuineBinaryHash
            }

            It 'hashes the cached binary once per command' {
                $Binary = New-CachedBinary 'darwin_arm64' 'cached terraform'
                Get-TerraformBinary -Version '1.9.8' | Should -Be $Binary
                Set-Content -Path $Binary -Value 'tampered' -NoNewline

                Get-TerraformBinary -Version '1.9.8' | Should -Be $Binary
                Should -Invoke Write-Warning -Times 0

                $script:VerifiedBinaries = @{}
                Get-Content -Path (Get-TerraformBinary -Version '1.9.8') -Raw | Should -Be 'genuine terraform'
                Should -Invoke Write-Warning -Exactly -Times 1 -ParameterFilter { $Message -like 'Cached Terraform binary failed SHA-256 verification*' }
            }

            It 'does not hash a binary it just extracted again in the same command' {
                Get-TerraformBinary -Version '1.9.8' | Out-Null
                Mock Get-FileSha256 { throw 'should not hash again' }

                { Get-TerraformBinary -Version '1.9.8' } | Should -Not -Throw
            }
        }

        Context 'concurrent runs' {
            It 'holds the release lock while downloading and extracting' {
                $script:LockState = @{ HeldDuringDownload = $null; HeldDuringExtract = $null }
                Mock Invoke-TerraformReleaseRequest {
                    $LockFile = Get-VendoredPath 'terraform_1.9.8_darwin_arm64.zip.lock'
                    try {
                        [System.IO.File]::Open($LockFile, 'OpenOrCreate', 'ReadWrite', 'None').Dispose()
                        $script:LockState.HeldDuringDownload = $false
                    }
                    catch [System.IO.IOException] {
                        $script:LockState.HeldDuringDownload = $true
                    }
                    Copy-Item -Path $FakeArchive -Destination $OutFile
                }

                Mock Expand-TerraformArchive {
                    $LockFile = Get-VendoredPath 'terraform_1.9.8_darwin_arm64.zip.lock'
                    try {
                        [System.IO.File]::Open($LockFile, 'OpenOrCreate', 'ReadWrite', 'None').Dispose()
                        $script:LockState.HeldDuringExtract = $false
                    }
                    catch [System.IO.IOException] {
                        $script:LockState.HeldDuringExtract = $true
                    }
                }

                Get-TerraformBinary -Version '1.9.8' | Out-Null

                Should -Invoke Invoke-TerraformReleaseRequest -Exactly -Times 1
                Should -Invoke Expand-TerraformArchive -Exactly -Times 1
                $script:LockState.HeldDuringDownload | Should -BeTrue
                $script:LockState.HeldDuringExtract | Should -BeTrue
                { [System.IO.File]::Open((Get-VendoredPath 'terraform_1.9.8_darwin_arm64.zip.lock'), 'OpenOrCreate', 'ReadWrite', 'None').Dispose() } | Should -Not -Throw
            }

            It 'releases the lock when verification fails' {
                $script:PublishedChecksums['terraform_1.9.8_darwin_arm64.zip'] = '0' * 64

                { Get-TerraformBinary -Version '1.9.8' } | Should -Throw '*SHA-256 checksum mismatch*'
                { [System.IO.File]::Open((Get-VendoredPath 'terraform_1.9.8_darwin_arm64.zip.lock'), 'OpenOrCreate', 'ReadWrite', 'None').Dispose() } | Should -Not -Throw
            }

            It 'uses the binary another run verified while it waited for the lock' {
                Mock Wait-TerraposhLock {
                    New-CachedBinary 'darwin_arm64' 'from the other run' | Out-Null
                    [System.IO.File]::Open($Path, 'OpenOrCreate', 'ReadWrite', 'None')
                }

                Get-Content -Path (Get-TerraformBinary -Version '1.9.8') -Raw | Should -Be 'from the other run'
                Should -Invoke Invoke-TerraformReleaseRequest -Times 0
            }
        }

        Context 'emulated amd64 fallback' {
            It 'prefers the native build when both are published' {
                Get-TerraformBinary -Version '1.9.8' | Should -BeLike "*terraform_1.9.8_darwin_arm64*"
                Should -Invoke Write-Warning -Times 0
            }

            It 'falls back to amd64 with a warning when no native build is published' {
                $script:PublishedChecksums.Remove('terraform_1.9.8_darwin_arm64.zip')

                $Binary = Get-TerraformBinary -Version '1.9.8'

                $Binary | Should -Be (Get-VendoredPath "terraform_1.9.8_darwin_amd64/${BinaryFileName}")
                Test-Path -Path (Get-VendoredPath 'terraform_1.9.8_darwin_amd64/.terraposh-sha256-fallback') | Should -BeTrue
                Test-Path -Path (Get-VendoredPath 'terraform_1.9.8_darwin_amd64/.terraposh-sha256') | Should -BeFalse
                Should -Invoke Invoke-TerraformReleaseRequest -Exactly -Times 1 -ParameterFilter {
                    $Uri -eq 'https://releases.hashicorp.com/terraform/1.9.8/terraform_1.9.8_darwin_amd64.zip'
                }
                Should -Invoke Write-Warning -Exactly -Times 1 -ParameterFilter { $Message -like '*no darwin_arm64 build, using darwin_amd64 under Rosetta 2.' }
            }

            It 'names x64 emulation rather than Rosetta 2 on Windows' {
                Mock Get-TerraformOS { 'windows' }
                $script:PublishedChecksums = @{ 'terraform_1.9.8_windows_amd64.zip' = $FakeHash }

                Get-TerraformBinary -Version '1.9.8' | Should -BeLike '*terraform_1.9.8_windows_amd64*'
                Should -Invoke Write-Warning -Exactly -Times 1 -ParameterFilter { $Message -like '*no windows_arm64 build, using windows_amd64 under x64 emulation.' }
            }

            It 'reuses a cached fallback binary without a warning or network access' {
                $script:PublishedChecksums.Remove('terraform_1.9.8_darwin_arm64.zip')
                Get-TerraformBinary -Version '1.9.8' | Out-Null

                Get-TerraformBinary -Version '1.9.8' | Should -BeLike "*terraform_1.9.8_darwin_amd64*"
                Should -Invoke Write-Warning -Exactly -Times 1
                Should -Invoke Get-TerraformReleaseChecksums -Exactly -Times 1
            }

            It 'does not reuse an unverified amd64 binary from before the architecture fix' {
                $LegacyDirectory = Get-VendoredPath 'terraform_1.9.8_darwin_amd64'
                New-Item -Path $LegacyDirectory -ItemType Directory | Out-Null
                Set-Content -Path (Join-Path -Path $LegacyDirectory -ChildPath $BinaryFileName) -Value 'legacy'

                Get-TerraformBinary -Version '1.9.8' | Should -BeLike "*terraform_1.9.8_darwin_arm64*"
            }

            It 'does not reuse a natively verified amd64 binary as a fallback' {
                New-CachedBinary 'darwin_amd64' 'native amd64' | Out-Null

                Get-TerraformBinary -Version '1.9.8' | Should -BeLike "*terraform_1.9.8_darwin_arm64*"
                Should -Invoke Get-TerraformReleaseChecksums -Exactly -Times 1
            }
        }
    }

    Describe 'Invoke-Terraposh' {
        It 'starts each command with a fresh binary verification cache' {
            $script:VerifiedBinaries = @{ 'stale' = 'a' * 64 }
            Mock Get-Config { @{ TerraformVersion = '1.9.8' } }
            Mock Get-TerraformBinary { 'terraform' }
            Mock Invoke-Expression { $global:LASTEXITCODE = 0 }

            Invoke-Terraposh -TerraformCommand 'version' -Explicit

            $script:VerifiedBinaries.Count | Should -Be 0
        }
    }

    Describe 'Get-TerraformBinary against releases.hashicorp.com' -Tag 'Integration' {
        BeforeAll {
            $script:IntegrationVendored = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "terraposh-integration-$([guid]::NewGuid().ToString('N'))"
            New-Item -Path $script:IntegrationVendored -ItemType Directory | Out-Null
            Mock Set-TerraformVendoredDirectory { $script:IntegrationVendored }
        }

        AfterAll {
            $Deadline = [DateTime]::UtcNow.AddSeconds(30)

            while ((Test-Path -Path $script:IntegrationVendored) -and [DateTime]::UtcNow -lt $Deadline) {
                Remove-Item -Path $script:IntegrationVendored -Recurse -Force -ErrorAction Ignore
                Start-Sleep -Milliseconds 500
            }
        }

        It 'downloads, verifies and runs Terraform <Version> for this platform' -TestCases @(
            @{ Version = '1.9.8' }
        ) {
            $Binary = Get-TerraformBinary -Version $Version
            $OS = Get-TerraformOS
            $Platform = (Split-Path -Leaf (Split-Path -Parent $Binary)) -replace "^terraform_${Version}_", ''

            $ExpectedPlatforms = @("${OS}_$(Get-TerraformArchitecture)")
            if ((Get-TerraformArchitecture) -eq 'arm64' -and $OS -in @('darwin', 'windows')) { $ExpectedPlatforms += "${OS}_amd64" }
            $Platform | Should -BeIn $ExpectedPlatforms
            Get-Content -Path (Join-Path -Path (Split-Path -Parent $Binary) -ChildPath '.terraposh-sha256*') -Force | Should -Be (Get-FileSha256 -Path $Binary)

            $Output = & $Binary version
            $LASTEXITCODE | Should -Be 0
            $Output[0] | Should -Be "Terraform v${Version}"
            $Output[1] | Should -Be "on ${Platform}"
        }
    }
}
