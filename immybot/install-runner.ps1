<#
.SYNOPSIS
    Installs the Onboarding Runner service on this device.
    Run once per machine as part of the ImmyBot software deployment.

.PARAMETER ApiUrl
    URL of the central API. Example: https://onboarding.yourcompany.com

.PARAMETER DeviceApiKey
    Device-specific API key (dev_...) for this machine.

.PARAMETER AnthropicApiKey
    Anthropic API key for Claude computer use.

.PARAMETER RunnerPackageUrl
    URL to the runner .zip package. Example: https://github.com/dillon-LACT/wraith-runner/releases/download/v0.1.0/runner.zip

.PARAMETER SlackWebhook
    Optional default Slack webhook for runner notifications.
#>

param(
    [Parameter(Mandatory)][string] $ApiUrl,
    [Parameter(Mandatory)][string] $DeviceApiKey,
    [Parameter(Mandatory)][string] $AnthropicApiKey,
    [Parameter(Mandatory)][string] $RunnerPackageUrl,
    [string] $SlackWebhook = ""
)

$ErrorActionPreference = "Stop"
$ServiceName = "OnboardingRunner"
$installPath = "C:\ProgramData\OnboardingRunner"
$nssmPath    = "C:\ProgramData\nssm\nssm.exe"
$pythonDir   = "C:\ProgramData\OnboardingRunner\python"
$pythonExe   = "$pythonDir\python.exe"

# ── Directories ────────────────────────────────────────────────────────────────
New-Item -ItemType Directory -Force -Path $installPath        | Out-Null
New-Item -ItemType Directory -Force -Path "$installPath\logs" | Out-Null
New-Item -ItemType Directory -Force -Path $pythonDir          | Out-Null

# ── Python ─────────────────────────────────────────────────────────────────────
if (-not (Test-Path $pythonExe)) {
    Write-Host "Installing Python..."
    $pythonInstaller = "$env:TEMP\python-installer.exe"
    Invoke-WebRequest -Uri "https://www.python.org/ftp/python/3.12.9/python-3.12.9-amd64.exe" -OutFile $pythonInstaller -UseBasicParsing
    $proc = Start-Process -FilePath $pythonInstaller `
        -ArgumentList "/quiet", "TargetDir=$pythonDir", "InstallAllUsers=1", "PrependPath=0", "Include_test=0" `
        -Wait -PassThru
    try { Remove-Item $pythonInstaller -Force } catch {}
    if ($proc.ExitCode -ne 0) { throw "Python installer exited with code $($proc.ExitCode)." }

    # Wait up to 60s for python.exe to appear in case of any post-install lag
    $deadline = (Get-Date).AddSeconds(60)
    while (-not (Test-Path $pythonExe) -and (Get-Date) -lt $deadline) {
        Write-Host "Waiting for Python to finish installing..."
        Start-Sleep -Seconds 3
    }
}
if (-not (Test-Path $pythonExe)) { throw "Python install failed — $pythonExe not found." }
Write-Host "Using Python: $pythonExe"

# ── Download + extract runner package ─────────────────────────────────────────
Write-Host "Downloading runner package..."
$zipPath = "$env:TEMP\onboarding-runner.zip"
Invoke-WebRequest -Uri $RunnerPackageUrl -OutFile $zipPath -UseBasicParsing
Expand-Archive -Path $zipPath -DestinationPath $installPath -Force
Remove-Item $zipPath

# ── Write .env ─────────────────────────────────────────────────────────────────
@"
ANTHROPIC_API_KEY=$AnthropicApiKey
WORKER_API_URL=$ApiUrl
WORKER_DEVICE_KEY=$DeviceApiKey
WORKER_POLL_INTERVAL=5
RUNNER_MAX_STEPS=20
RUNNER_SCREENSHOT_SCALE=0.75
RUNNER_STEP_DELAY_MS=800
LOG_LEVEL=INFO
SLACK_WEBHOOK=$SlackWebhook
"@ | Set-Content "$installPath\runner\.env" -Encoding UTF8

# ── pip install ────────────────────────────────────────────────────────────────
Write-Host "Installing Python dependencies..."
$pipArgs = @(
    "-m", "pip", "install",
    "-r", "$installPath\runner\requirements.txt",
    "--timeout", "60",
    "--trusted-host", "pypi.org",
    "--trusted-host", "pypi.python.org",
    "--trusted-host", "files.pythonhosted.org",
    "--quiet"
)
$pipSuccess = $false
for ($attempt = 1; $attempt -le 3; $attempt++) {
    Write-Host "pip install attempt $attempt of 3..."
    & $pythonExe @pipArgs
    if ($LASTEXITCODE -eq 0) { $pipSuccess = $true; break }
    if ($attempt -lt 3) { Start-Sleep -Seconds 10 }
}
if (-not $pipSuccess) { throw "pip install failed after 3 attempts." }

# ── NSSM ───────────────────────────────────────────────────────────────────────
if (-not (Test-Path $nssmPath)) {
    Write-Host "Downloading NSSM..."
    $nssmZip = "$env:TEMP\nssm.zip"
    Invoke-WebRequest -Uri "https://nssm.cc/release/nssm-2.24.zip" -OutFile $nssmZip -UseBasicParsing
    Expand-Archive -Path $nssmZip -DestinationPath "$env:TEMP\nssm-extract" -Force
    New-Item -ItemType Directory -Force -Path "C:\ProgramData\nssm" | Out-Null
    Copy-Item "$env:TEMP\nssm-extract\nssm-2.24\win64\nssm.exe" $nssmPath
    Remove-Item $nssmZip -Force
    Remove-Item "$env:TEMP\nssm-extract" -Recurse -Force
}

# ── Remove existing service ────────────────────────────────────────────────────
$existingSvc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($existingSvc) {
    Write-Host "Removing existing service..."
    & $nssmPath stop   $ServiceName confirm 2>$null
    & $nssmPath remove $ServiceName confirm
}

# ── Register + start service ───────────────────────────────────────────────────
& $nssmPath install $ServiceName $pythonExe "worker.py"
& $nssmPath set     $ServiceName AppDirectory   "$installPath\runner"
& $nssmPath set     $ServiceName DisplayName    "Onboarding Runner"
& $nssmPath set     $ServiceName Description    "AI-powered app sign-in automation worker"
& $nssmPath set     $ServiceName Start          SERVICE_AUTO_START
& $nssmPath set     $ServiceName AppStdout      "$installPath\logs\service.log"
& $nssmPath set     $ServiceName AppStderr      "$installPath\logs\service.log"
& $nssmPath set     $ServiceName AppRotateFiles 1
& $nssmPath set     $ServiceName AppRotateBytes 5242880
& $nssmPath start   $ServiceName

Start-Sleep -Seconds 3
$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($svc.Status -ne "Running") {
    throw "OnboardingRunner failed to start. Check $installPath\logs\service.log"
}

# ── Write version to registry for ImmyBot detection ───────────────────────────
$regPath = "HKLM:\SOFTWARE\WraithRunner"
New-Item -Path $regPath -Force | Out-Null
Set-ItemProperty -Path $regPath -Name "Version" -Value "1.0.0"
Set-ItemProperty -Path $regPath -Name "InstallPath" -Value $installPath

Write-Host "Onboarding Runner is running."
