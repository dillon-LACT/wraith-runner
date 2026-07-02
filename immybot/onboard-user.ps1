<#
.SYNOPSIS
    Per-user onboarding: submits sign-in jobs to the central API for each app in the list.
    Run this as an ImmyBot Maintenance Task when onboarding a new user to a device.

.PARAMETER ApiUrl
    URL of the central API. Example: https://onboarding.yourcompany.com

.PARAMETER TenantApiKey
    The tenant-level API key (ten_...) for your MSP or customer tenant.

.PARAMETER DeviceId
    The device identifier for this machine. Should match what was registered.
    Tip: use $env:COMPUTERNAME so ImmyBot fills this in automatically.

.PARAMETER Client
    Customer/client name. Example: "Acme Corp"

.PARAMETER UserEmail
    The user being onboarded. Example: "jane@acme.com"

.PARAMETER Apps
    Comma-separated list of apps to sign into.
    Available: zoom
    Example: "zoom,teams,slack"

.PARAMETER Method
    Sign-in method: "sso", "user_pass", or "skip"

.PARAMETER Username
    Username/email for user_pass method. Usually same as UserEmail.

.PARAMETER Password
    Password for user_pass method.

.PARAMETER SsoDomain
    SSO domain slug for SSO method. Example: "acmecorp" (not acmecorp.zoom.us)

.PARAMETER SlackWebhook
    Optional Slack webhook URL to receive results for this job.
    Overrides the runner's default webhook.

.PARAMETER WaitForResults
    If true, polls for job completion and prints results. Default: true.

.PARAMETER TimeoutSeconds
    How long to wait per job before giving up polling. Default: 300 (5 min)

.PARAMETER DeviceApiKey
    Device-specific API key (dev_...) used by the installer to configure the runner service.

.PARAMETER AnthropicApiKey
    Anthropic API key for Claude computer use. Used by the installer.

.PARAMETER RunnerPackageUrl
    URL to the runner .zip package (GitHub Releases). Used by the installer.
#>

param(
    [Parameter(Mandatory)][string]   $ApiUrl,
    [Parameter(Mandatory)][string]   $TenantApiKey,
    [Parameter(Mandatory)][string]   $DeviceId,
    [Parameter(Mandatory)][string]   $Client,
    [Parameter(Mandatory)][string]   $UserEmail,
    [Parameter(Mandatory)][string]   $Apps,
    [Parameter(Mandatory)][string]   $Method,
    [Parameter(Mandatory)][string]   $DeviceApiKey,
    [Parameter(Mandatory)][string]   $AnthropicApiKey,
    [Parameter(Mandatory)][string]   $RunnerPackageUrl,
    [string] $Username       = "",
    [string] $Password       = "",
    [string] $SsoDomain      = "",
    [string] $SlackWebhook   = "",
    [bool]   $WaitForResults = $true,
    [int]    $TimeoutSeconds = 300
)

$ErrorActionPreference = "Stop"
$headers = @{ "X-API-Key" = $TenantApiKey; "Content-Type" = "application/json" }

$appList = $Apps -split "," | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ }
if ($appList.Count -eq 0) { throw "No apps specified." }

Write-Host "Onboarding $UserEmail on $DeviceId"
Write-Host "Apps: $($appList -join ', ')  |  Method: $Method"
Write-Host ""

# ── Submit one job per app ─────────────────────────────────────────────────────
$jobIds = @{}

foreach ($app in $appList) {
    $body = @{
        device_id = $DeviceId
        client    = $Client
        user      = $UserEmail
        app       = $app
        method    = $Method
    }
    if ($Username)     { $body.username      = $Username }
    if ($Password)     { $body.password      = $Password }
    if ($SsoDomain)    { $body.sso_domain    = $SsoDomain }
    if ($SlackWebhook) { $body.slack_webhook = $SlackWebhook }

    try {
        $resp = Invoke-RestMethod -Uri "$ApiUrl/jobs" -Method Post `
            -Headers $headers -Body ($body | ConvertTo-Json) -UseBasicParsing
        $jobIds[$app] = $resp.job_id
        Write-Host "[$app] Job submitted: $($resp.job_id)"
    } catch {
        Write-Warning "[$app] Failed to submit job: $_"
        $jobIds[$app] = $null
    }
}

if (-not $WaitForResults) {
    Write-Host ""
    Write-Host "Jobs submitted. Not waiting for results."
    return
}

# ── Poll for results ───────────────────────────────────────────────────────────
Write-Host ""
Write-Host "Waiting for results (timeout: ${TimeoutSeconds}s per job)..."
Write-Host ""

$results = @{}
$pollHeaders = @{ "X-API-Key" = $TenantApiKey }

foreach ($app in $appList) {
    $jobId = $jobIds[$app]
    if (-not $jobId) {
        $results[$app] = @{ status = "submit_failed" }
        continue
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $done = $false

    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 5
        try {
            $r = Invoke-RestMethod -Uri "$ApiUrl/jobs/$jobId" `
                -Headers $pollHeaders -UseBasicParsing
            if ($r.status -eq "completed") {
                $results[$app] = $r
                $done = $true
                break
            }
        } catch {
            Write-Warning "[$app] Poll error: $_"
        }
    }

    if (-not $done) {
        $results[$app] = @{ result_status = "poll_timeout"; result_detail = "No result within ${TimeoutSeconds}s" }
    }
}

# ── Print summary ──────────────────────────────────────────────────────────────
Write-Host "──────────────────────────────────────"
Write-Host "Results for $UserEmail on $DeviceId"
Write-Host "──────────────────────────────────────"

$allSuccess = $true
foreach ($app in $appList) {
    $r = $results[$app]
    $status = if ($r.result_status) { $r.result_status } elseif ($r.status) { $r.status } else { "unknown" }
    $detail = if ($r.result_detail) { $r.result_detail } else { "" }
    $icon = if ($status -eq "success") { "✓" } else { "✗" }
    Write-Host "$icon  $app — $status  $detail"
    if ($status -ne "success") { $allSuccess = $false }
}

Write-Host "──────────────────────────────────────"
if ($allSuccess) {
    Write-Host "All apps signed in successfully." -ForegroundColor Green
} else {
    Write-Host "Some apps need attention — check Slack for details." -ForegroundColor Yellow
}
