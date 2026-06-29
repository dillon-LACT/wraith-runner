# ImmyBot Task: Onboard User (Metascript — runs server-side, no Invoke-ImmyCommand needed)
#
# Task Parameters to define in ImmyBot UI:
#   $ApiUrl           - Central API URL
#   $TenantApiKey     - Tenant API key (ten_...)
#   $DeviceId         - Device identifier (use $env:COMPUTERNAME or set manually)
#   $Client           - Customer/client name (e.g. "Acme Corp")
#   $UserEmail        - User being onboarded (e.g. jane@acme.com)
#   $Apps             - Comma-separated apps (e.g. "zoom,teams")
#   $SignInMethod     - "sso", "user_pass", or "skip"
#   $Username         - (optional) username for user_pass
#   $Password         - (optional) password for user_pass
#   $SsoDomain        - (optional) SSO domain slug for sso method
#   $SlackWebhook     - (optional) override Slack webhook for this job
#   $TimeoutSeconds   - (optional) seconds to wait per job, default 300
#
# Installer Parameters (also defined here so ImmyBot surfaces them in the deployment UI):
#   $DeviceApiKey     - Device-specific API key (dev_...) used by install-runner.ps1
#   $AnthropicApiKey  - Anthropic API key for Claude used by install-runner.ps1
#   $RunnerPackageUrl - URL to runner .zip used by install-runner.ps1

if (-not $TimeoutSeconds) { $TimeoutSeconds = 300 }

$appList = $Apps -split "," | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ }
if ($appList.Count -eq 0) { throw "No apps specified." }

$postHeaders = @{ "X-API-Key" = $TenantApiKey; "Content-Type" = "application/json" }
$getHeaders  = @{ "X-API-Key" = $TenantApiKey }

switch ($method) {
    "set" {
        Write-Host "Onboarding $UserEmail on $DeviceId ($Client)"
        Write-Host "Apps: $($appList -join ', ')  |  Method: $SignInMethod"

        $jobIds  = @{}
        $failures = [System.Collections.Generic.List[string]]::new()

        # Submit all jobs, continue on individual failures
        foreach ($app in $appList) {
            $body = @{
                device_id = $DeviceId
                client    = $Client
                user      = $UserEmail
                app       = $app
                method    = $SignInMethod
            }
            if ($Username)     { $body.username      = $Username }
            if ($Password)     { $body.password      = $Password }
            if ($SsoDomain)    { $body.sso_domain    = $SsoDomain }
            if ($SlackWebhook) { $body.slack_webhook = $SlackWebhook }

            try {
                $resp = Invoke-RestMethod -Uri "$ApiUrl/jobs" -Method Post `
                    -Headers $postHeaders -Body ($body | ConvertTo-Json) -UseBasicParsing
                $jobIds[$app] = $resp.job_id
                Write-Host "[$app] Submitted job $($resp.job_id)"
            } catch {
                Write-Warning "[$app] Failed to submit job: $_"
                $failures.Add($app)
            }
        }

        # Poll for results on successfully submitted jobs
        foreach ($app in $jobIds.Keys) {
            $jobId    = $jobIds[$app]
            $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
            $done     = $false

            while ((Get-Date) -lt $deadline) {
                Start-Sleep -Seconds 5
                try {
                    $r = Invoke-RestMethod -Uri "$ApiUrl/jobs/$jobId" -Headers $getHeaders -UseBasicParsing
                    if ($r.status -eq "completed") {
                        Write-Host "[$app] $($r.result_status): $($r.result_detail)"
                        if ($r.result_status -ne "success") { $failures.Add($app) }
                        $done = $true
                        break
                    }
                } catch {
                    Write-Warning "[$app] Poll error: $_"
                }
            }

            if (-not $done) {
                Write-Warning "[$app] Timed out after ${TimeoutSeconds}s"
                $failures.Add($app)
            }
        }

        if ($failures.Count -gt 0) {
            throw "The following apps did not complete successfully: $($failures -join ', '). Check Slack for details."
        }
    }
    default {
        # test/get — always re-run onboarding (sign-in state can't be verified without running the agent)
        return $false
    }
}
