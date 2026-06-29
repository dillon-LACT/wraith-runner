param($Computer, [TimeSpan]$TimeoutDuration = (New-TimeSpan -Minutes 20),[switch]$SkipUpdates,[switch]$IgnoreRebootPreference)
$VerbosePreference = 'Continue'
if($null -eq $Computer)
{
    $Computer = Get-ImmyComputer
}

if($rebootPreference -eq "Suppress" -and $IgnoreRebootPreference -ne $true) {
    Write-Host "SessionRebootPreference: $RebootPreference"
    Write-Host "Skipping Restart"
    return
}
if($IgnoreRebootPreference -eq $true)
{
    Write-Host "IgnoreRebootPreference specified"
}
Write-Host "Restarting Computer"
Write-Host "Verifying post restart connectivity"
Set-ActiveWirelessConnectionModeToAuto -Computer $Computer
Write-Verbose "Getting last boot time"
try
{
    [DateTime]$LastBootTime = Get-LastBootTime -Computer $Computer
}
catch{
    Write-Error "Aborting: Unable to retrieve last boot time"
    return
}
Write-Verbose "LastBootTime: $($LastBootTime)"
try
{
    $Computer | Invoke-ImmyCommand { 
        $BitlockerModuleInstalled = $null -ne (Get-Module -ListAvailable Bitlocker)
        if($BitlockerModuleInstalled)
        {
            Write-Verbose "Importing Bitlocker Module"
            $VerbosePreference = 'SilentlyContinue'
            Import-Module Bitlocker -WarningAction SilentlyContinue -Verbose:$false
            try
            {
                $BitlockerEnabled = "Off" -ne (Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction SilentlyContinue | select -Expand ProtectionStatus)
                if($BitlockerEnabled)
                {
                    Write-Verbose "Running Suspend-Bitlocker"
                    Suspend-Bitlocker -Mountpoint $env:SystemDrive -RebootCount 1
                }
                $BitlockerEnabled = "Off" -ne (Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction SilentlyContinue | select -Expand ProtectionStatus)
                if($BitlockerEnabled)
                {
                    Write-Warning "Skipping Restart, unable to suspend Bitlocker"
                    return
                }
                else
                {
                    Write-Host "Successfully suspended Bitlocker"
                }
            }
            catch
            {
                Write-Warning "Exception thrown when attempting to suspend bitlocker"
            }
        }
        else
        {
            Write-Warning "BitLocker module not found, using manage-bde"
            Manage-bde -Protectors -Disable ($env:systemdrive) -RebootCount 1                
        }
        Write-Host "Executing Reboot"
        if($using:SkipUpdates)
        {
            Write-Host "Stopping wuauserv to skip updates"
            net stop wuauserv
        }
        shutdown /t 1 /g /f
        # Restart-Computer -Force
    }
}
catch
{
    # Commented this out because it seems that the -Force command causes an exception
    #Write-Warning "Exception while attempting to Restart the computer"
    #return
}

[DateTime]$BootTime = $LastBootTime
if(!$LastBootTime)
{
    Write-Warning "Unable to retrieve LastBootTime. Aborting..."
    return
}
Write-Debug "LastBootTime: $LastBootTime"
$TimeoutTime = (Get-Date) + $TimeoutDuration
$RebootComplete = $false

$waitCmd = Get-Command Wait-ImmyComputer -ErrorAction SilentlyContinue
if ($waitCmd)
{
    $timeoutInSeconds = $TimeoutDuration.TotalSeconds * 0.80
    $waitTimeout = New-TimeSpan -Seconds $timeoutInSeconds 
    $newWaitTimeoutInSeconds = $waitTimeout.TotalSeconds
    Write-Host "Waiting $timeoutInSeconds seconds for an agent to reconnect..."
    try 
    {   
        [int]$secondsWaited = measure-command {
            Wait-ImmyComputer -For Reboot -Timeout $waitTimeout
        } | Select -expand TotalSeconds
        Write-Host "An agent reconnected after waiting $secondsWaited seconds."
    } 
    catch
    {
        Write-Error $_
    }
}

$pollingInterval = 0;
do {
    try
    {
        Start-Sleep -s $pollingInterval
        $BootTime = Get-LastBootTime -Computer $Computer
        $RebootComplete = $BootTime -ne $LastBootTime
        Write-Host "$((Get-Date).ToString('s')): Comparing : $($BootTime.ToString('s')) -gt $($LastBootTime.ToString('s')) = $RebootComplete"
    }
    catch
    {
        Write-Host "Computer is offline, Unable to retrieve BootTime..."
    }
    if ($pollingInterval -lt 30) 
    {
        $pollingInterval += 5 
    }
    $TimedOut = (Get-Date) -gt $TimeoutTime
} while($TimedOut -eq $false -and $RebootComplete -eq $false)
if($TimedOut)
{
    Write-Warning "Timeout waiting $($TimeoutDuration.TotalMinutes) minutes for $($Computer.Name) to come back online."
}
else
{
    Write-Host "$($Computer.Name) is Online. Reboot complete"
}