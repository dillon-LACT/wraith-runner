$version = Get-ItemProperty -Path "HKLM:\SOFTWARE\WraithRunner" -Name "Version" -ErrorAction SilentlyContinue
if ($version) {
    return [String]$version.Version
}
