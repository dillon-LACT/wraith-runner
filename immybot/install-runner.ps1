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
    # Edit ._pth without BOM — PS5.1 Set-Content -Encoding UTF8 adds a BOM which
    # breaks Python's path parser (it prepends BOM bytes to "python312.zip").
    $pthFile = "$pythonDir\python312._pth"
    $pthContent = [System.IO.File]::ReadAllText($pthFile) -replace '#import site', 'import site'
    [System.IO.File]::WriteAllText($pthFile, $pthContent, [System.Text.Encoding]::ASCII)
}
if (-not (Test-Path $pythonExe)) { throw "Python install failed — $pythonExe not found." }
Write-Host "Using Python: $pythonExe"

# ── Download + extract runner package ─────────────────────────────────────────
# Must happen before pip bootstrap so runner/vendor/ wheels are available.
Write-Host "Downloading runner package..."
$zipPath = "$env:TEMP\onboarding-runner.zip"
Invoke-Download -Uri $RunnerPackageUrl -OutFile $zipPath
Expand-Archive -Path $zipPath -DestinationPath $installPath -Force
Remove-Item $zipPath

# ── Bootstrap pip from bundled wheel (no network needed) ──────────────────────
# get-pip.py hits pypi.org/simple/pip/ at the TCP level — blocked on this machine.
# A .whl file is just a zip; expanding it into site-packages installs pip directly.
$vendorDir    = "$installPath\runner\vendor"
$sitePackages = "$pythonDir\Lib\site-packages"
New-Item -ItemType Directory -Force -Path $sitePackages | Out-Null
$pipWhl = (Get-ChildItem "$vendorDir\pip-*.whl" | Select-Object -First 1).FullName
if (-not $pipWhl) { throw "pip wheel not found in vendor/. Re-build runner.zip." }
Write-Host "Installing pip from bundled wheel..."
# PS5.1 Expand-Archive rejects .whl extension — copy to .zip first.
$pipZip = "$env:TEMP\pip-install.zip"
Copy-Item $pipWhl $pipZip -Force
Expand-Archive -Path $pipZip -DestinationPath $sitePackages -Force
Remove-Item $pipZip -Force

# Pre-install setuptools + wheel so pip can build the .tar.gz source dists
# (PyAutoGUI and its deps). Installing wheels doesn't need a build backend,
# so this works even though setuptools isn't in site-packages yet.
Write-Host "Pre-installing build tools..."
& $pythonExe -m pip install setuptools wheel `
    --no-index --find-links $vendorDir `
    --no-warn-script-location
if ($LASTEXITCODE -ne 0) { throw "Failed to pre-install setuptools/wheel." }

# ── Write .env ─────────────────────────────────────────────────────────────────
$envContent = "ANTHROPIC_API_KEY=$AnthropicApiKey`nWORKER_API_URL=$ApiUrl`nWORKER_DEVICE_KEY=$DeviceApiKey`nWORKER_POLL_INTERVAL=5`nRUNNER_MAX_STEPS=20`nRUNNER_SCREENSHOT_SCALE=0.75`nRUNNER_STEP_DELAY_MS=800`nLOG_LEVEL=INFO`nSLACK_WEBHOOK=$SlackWebhook`n"
# Write without BOM — PS5.1 Set-Content -Encoding UTF8 adds a BOM which dotenv reads as part of the first key name.
[System.IO.File]::WriteAllText("$installPath\runner\.env", $envContent, [System.Text.Encoding]::ASCII)

# ── pip install (fully offline via bundled vendor/) ────────────────────────────
Write-Host "Installing Python dependencies from vendor/..."
$pipArgs = @(
    "-m", "pip", "install",
    "-r", "$installPath\runner\requirements.txt",
    "--no-index",
    "--find-links", $vendorDir,
    "--no-build-isolation"
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

# ── Remove legacy NSSM service, if migrating an older install ─────────────────
# NSSM ran worker.py as SYSTEM in Session 0, where screen capture / mouse and
# keyboard automation don't work. A Scheduled Task running as the interactive
# logged-on user (below) replaces it. python.exe (vs pythonw.exe) also used to
# spawn a visible console window that could steal foreground focus from the
# target app and swallow its clicks/keystrokes — pythonw.exe has no console.
$existingSvc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($existingSvc) {
    Write-Host "Removing legacy NSSM service..."
    if (Test-Path $nssmPath) {
        & $nssmPath stop   $ServiceName confirm 2>$null
        & $nssmPath remove $ServiceName confirm
    } else {
        sc.exe delete $ServiceName | Out-Null
    }
}

# ── Determine the interactive logged-on user ──────────────────────────────────
$activeSession = quser 2>$null | Select-Object -Skip 1 | ForEach-Object {
    $parts = ($_ -replace '^\s*>', '') -split '\s+' | Where-Object { $_ }
    [PSCustomObject]@{ User = $parts[0]; State = $parts[3] }
} | Where-Object { $_.State -eq 'Active' } | Select-Object -First 1

if (-not $activeSession) {
    throw "No active interactive user session found. The runner must be installed while a user is logged on locally (screen capture and input automation require an interactive session)."
}
$taskUser = $activeSession.User
Write-Host "Registering scheduled task to run as interactive user: $taskUser"

# ── Register + start scheduled task (pythonw.exe — no console window) ────────
$pythonwExe = "$pythonDir\pythonw.exe"
Unregister-ScheduledTask -TaskName $ServiceName -Confirm:$false -ErrorAction SilentlyContinue
$action    = New-ScheduledTaskAction -Execute $pythonwExe -Argument "worker.py" -WorkingDirectory "$installPath\runner"
$trigger   = New-ScheduledTaskTrigger -AtLogOn -User $taskUser
$principal = New-ScheduledTaskPrincipal -UserId $taskUser -LogonType Interactive -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -RestartCount 5 -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit (New-TimeSpan -Days 365)
Register-ScheduledTask -TaskName $ServiceName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName $ServiceName

Start-Sleep -Seconds 3
$taskState = (Get-ScheduledTask -TaskName $ServiceName).State
if ($taskState -ne "Running") {
    throw "OnboardingRunner scheduled task failed to start (state=$taskState). Check $installPath\logs\service.log"
}

# ── Write version to registry for ImmyBot detection ───────────────────────────
$regPath = "HKLM:\SOFTWARE\WraithRunner"
New-Item -Path $regPath -Force | Out-Null
Set-ItemProperty -Path $regPath -Name "Version" -Value "1.0.0"
Set-ItemProperty -Path $regPath -Name "InstallPath" -Value $installPath

Write-Host "Onboarding Runner is running."
