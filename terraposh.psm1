function Invoke-Terraposh {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'

    $Args

    terraform -version
}

# Create aliases and export members
Set-Alias -Name 'terraposh' -Value 'Invoke-Terraposh'
Export-ModuleMember -Function 'Invoke-Terraposh' -Alias 'terraposh'
