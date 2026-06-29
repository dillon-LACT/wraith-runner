$targetPackageFamilyName = "Agilebits.1Password_amwd9z03whsfe"

try {
    # $SystemPackage = Detect-Software -RegExSoftwareSearchString $DetectionString

    Invoke-ImmyCommand {
        # Per-user install (eg. Install behavior in Intune is User).
        $UserPackage = Get-AppxPackage -AllUsers | Where-Object { $_.PackageFamilyName -eq $using:targetPackageFamilyName }

        if ($UserPackage) {
            Write-Verbose "A user context 1Password is already installed." -Verbose
            return [String]$UserPackage.Version
        # } elseif ($using:SystemPackage) {
        #     Write-Verbose "A machine context 1Password is already installed." -Verbose
        #     return [String]$($using:SystemPackage).DisplayVersion
        } else {
            Write-Verbose "A user context 1Password installation wasn't found." -Verbose
            return $null
        }
    } -Verbose
} catch {
    Write-Warning "An error occured while attempting to find installation."
    return $null
}