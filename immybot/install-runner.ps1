# ImmyBot Task: Onboarding Runner
#
# Task Parameters to define in ImmyBot UI:
#   $ApiUrl           - Central API URL (e.g. https://onboarding.yourcompany.com)
#   $DeviceApiKey     - Device-specific API key (dev_...)
#   $AnthropicApiKey  - Anthropic API key for Claude
#   $RunnerPackageUrl - URL to runner .zip (GitHub Releases, Azure Blob, S3, etc.)
#   $SlackWebhook     - (optional) Slack webhook for notifications

$ServiceName = "OnboardingRunner"

$ServiceStatus = Invoke-ImmyCommand -IncludeLocals {
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    return $svc?.Status.ToString()
}

switch ($method) {
    "set" {
        $envFileContent = @"
ANTHROPIC_API_KEY=$AnthropicApiKey
WORKER_API_URL=$ApiUrl
WORKER_DEVICE_KEY=$DeviceApiKey
WORKER_POLL_INTERVAL=5
RUNNER_MAX_STEPS=20
RUNNER_SCREENSHOT_SCALE=0.75
RUNNER_STEP_DELAY_MS=800
LOG_LEVEL=INFO
SLACK_WEBHOOK=$SlackWebhook
"@
        Invoke-ImmyCommand -IncludeLocals {
            $installPath = "C:\ProgramData\OnboardingRunner"
            $nssmPath    = "C:\ProgramData\nssm\nssm.exe"

            # Python
            if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
                Write-Host "Installing Python..."
                winget install --id Python.Python.3.12 --silent --accept-source-agreements --accept-package-agreements
                $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" +
                            [System.Environment]::GetEnvironmentVariable("Path","User")
            }

            # Directories
            New-Item -ItemType Directory -Force -Path $installPath        | Out-Null
            New-Item -ItemType Directory -Force -Path "$installPath\logs" | Out-Null

            # Download + extract runner package
            Write-Host "Downloading runner package..."
            $zipPath = "$env:TEMP\onboarding-runner.zip"
            Invoke-WebRequest -Uri $RunnerPackageUrl -OutFile $zipPath -UseBasicParsing
            Expand-Archive -Path $zipPath -DestinationPath $installPath -Force
            Remove-Item $zipPath

            # Write .env
            $envFileContent | Set-Content "$installPath\.env" -Encoding UTF8

            # pip install
            Write-Host "Installing Python dependencies..."
            & python -m pip install -r "$installPath\requirements.txt" --quiet

            # NSSM
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

            # Remove existing service if present
            $existingSvc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
            if ($existingSvc) {
                Write-Host "Removing existing service..."
                & $nssmPath stop   $ServiceName confirm 2>$null
                & $nssmPath remove $ServiceName confirm
            }

            # Register + start service
            $pythonExe = (Get-Command python).Source
            & $nssmPath install $ServiceName $pythonExe "worker.py"
            & $nssmPath set     $ServiceName AppDirectory   $installPath
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
            Write-Host "Onboarding Runner is running."
        }
    }
    default {
        $isRunning = $ServiceStatus -eq "Running"
        if (-not $isRunning) {
            Write-Warning "OnboardingRunner service is: $($ServiceStatus ?? 'not installed')"
        }
        return $isRunning
    }
}
