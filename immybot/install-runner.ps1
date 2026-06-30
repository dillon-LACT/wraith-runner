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
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ServiceName = "OnboardingRunner"
$installPath = "C:\ProgramData\OnboardingRunner"
$nssmPath    = "C:\ProgramData\nssm\nssm.exe"
$pythonDir   = "C:\ProgramData\OnboardingRunner\python"
$pythonExe   = "$pythonDir\python.exe"

function Invoke-Download {
    param([string]$Uri, [string]$OutFile)
    for ($i = 1; $i -le 3; $i++) {
        try {
            Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing
            return
        } catch {
            if ($i -eq 3) { throw }
            Write-Host "Download failed (attempt $i/3), retrying in 5s..."
            Start-Sleep -Seconds 5
        }
    }
}

# ── Directories ────────────────────────────────────────────────────────────────
New-Item -ItemType Directory -Force -Path $installPath        | Out-Null
New-Item -ItemType Directory -Force -Path "$installPath\logs" | Out-Null
try { Start-Transcript -Path "$installPath\logs\install.log" -Force | Out-Null } catch {}

# ── Python ─────────────────────────────────────────────────────────────────────
# Validate existing install: embeddable package has python312.zip (stdlib), full
# install has Lib\. Running the broken exe to check hangs on fatal startup errors.
$pythonOk = (Test-Path $pythonExe) -and ((Test-Path "$pythonDir\python312.zip") -or (Test-Path "$pythonDir\Lib"))
if (-not $pythonOk) {
    # Use the embeddable package so python.exe + stdlib live in one directory.
    # The full MSI installer splits python.exe (TargetDir) from Lib/ (default
    # system path) when another Python is already registered in HKLM, which
    # makes the interpreter unable to find its own stdlib.
    Write-Host "Installing Python embeddable package (removing old install if present)..."
    if (Test-Path $pythonDir) { Remove-Item $pythonDir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $pythonDir | Out-Null

    $pythonZip = "$env:TEMP\python-embed.zip"
    Invoke-Download -Uri "https://www.python.org/ftp/python/3.12.9/python-3.12.9-embed-amd64.zip" -OutFile $pythonZip
    Expand-Archive -Path $pythonZip -DestinationPath $pythonDir -Force
    Remove-Item $pythonZip

    # Embeddable Python disables site-packages by default; uncomment 'import site'
    # in the ._pth file so that pip and installed packages are discoverable.
    $pthFile = "$pythonDir\python312._pth"
    (Get-Content $pthFile -Raw) -replace '#import site', 'import site' | Set-Content $pthFile -Encoding UTF8

    # Bootstrap pip (not bundled with the embeddable package)
    Write-Host "Bootstrapping pip..."
    $getPip = "$env:TEMP\get-pip.py"
    Invoke-Download -Uri "https://bootstrap.pypa.io/get-pip.py" -OutFile $getPip
    & $pythonExe $getPip --no-warn-script-location
    if ($LASTEXITCODE -ne 0) { throw "pip bootstrap failed." }
    Remove-Item $getPip -Force
}
if (-not (Test-Path $pythonExe)) { throw "Python install failed — $pythonExe not found." }
Write-Host "Using Python: $pythonExe"

# ── Download + extract runner package ─────────────────────────────────────────
Write-Host "Downloading runner package..."
$zipPath = "$env:TEMP\onboarding-runner.zip"
Invoke-Download -Uri $RunnerPackageUrl -OutFile $zipPath
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
    "--timeout", "30",
    "--retries", "1",
    "--trusted-host", "pypi.org",
    "--trusted-host", "pypi.python.org",
    "--trusted-host", "files.pythonhosted.org"
)
$pipSuccess = $false
for ($attempt = 1; $attempt -le 3; $attempt++) {
    Write-Host "pip install attempt $attempt of 3..."
    & $pythonExe @pipArgs
    if ($LASTEXITCODE -eq 0) { $pipSuccess = $true; break }
    if ($attempt -lt 3) { Start-Sleep -Seconds 10 }
}
if (-not $pipSuccess) {
    Write-Error "pip install failed after 3 attempts."
    exit 1
}

# ── NSSM ───────────────────────────────────────────────────────────────────────
if (-not (Test-Path $nssmPath)) {
    Write-Host "Downloading NSSM..."
    $nssmZip = "$env:TEMP\nssm.zip"
    Invoke-Download -Uri "https://nssm.cc/release/nssm-2.24.zip" -OutFile $nssmZip
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
