$Service = Invoke-ImmyCommand{
    $Service = Get-Service -Name "UCPD" -ErrorAction Ignore
    if($Service) { #Cannot return the service directly, the Status and StartTypes will serialize with the enum value (int) and not the name (string)
        $ServiceInfo = New-Object PSObject -Property @{
            Name = $Service.Name
            Status = $Service.Status.ToString()
            ServiceType = $Service.ServiceType
            StartType = $Service.StartType.ToString()
        }
        return $ServiceInfo #return the service info with the strings instead of the enums
    }
    return $null
}
if(!$Service) { #If there is no UCPD service, there is nothing to configure. This is here for versions of Windows that do not (yet) have this installed, or perhaps in the future if it gets removed.
    Write-Host "UCPD not present/installed on this system."
    return $true
}

$ServiceDesiredState = if($Enabled){'Running'}else{'Stopped'} #Desired State of Service, based on $Enabled
$ServiceIsInDesiredState = ($Service.Status -eq $ServiceDesiredState)

$ScheduledTaskDesiredState = if($Enabled){'Ready'}else{'Disabled'} #Desired State of Scheduled Task, based on $Enabled
ScheduledTaskShould-Be -TaskName "UCPD velocity" -DesiredState $ScheduledTaskDesiredState #Check Scheduled Task and return boolean, or set to desired state

switch($method) {
    "set" {
        if(!$ServiceIsInDesiredState) { #We will only attempt service configuration and reboot if the service is not already in the desired state
            if($Enabled) { #if the service should be enabled,
                Invoke-ImmyCommand { #enable it as a system driver service
                    Start-Process "sc.exe" -ArgumentList "config UCPD start= system"
                }
            }
            else { #otherwise
                Invoke-ImmyCommand { #the service should be disabled
                    Start-Process "sc.exe" -ArgumentList "config UCPD start= disabled"
                }
            }
            if($RebootPreference -eq "Suppress") { #if reboots are suppressed, throw an exception because changes can't be confirmed until after reboot
                Throw "UCPD cannot be enabled or disabled without a system reboot, and reboots were suppressed."
            }
            Restart-ComputerAndWait #reboot the machine
        }
    }
    default {
        if(!$ServiceIsInDesiredState) {
            Write-Warning "$($Service.Name) Service is $($Service.Status) and should be $ServiceDesiredState"
        }
        return $ServiceIsInDesiredState
    }
}