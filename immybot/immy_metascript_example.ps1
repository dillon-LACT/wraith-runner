# -------------------------------------------------------------
# PowerShell Wrapper to Bootstrap PsExec & Launch Desktop Automation
# -------------------------------------------------------------
# these are going to be sign in with google, try to implement that in login script
#
#




<#
* This script will eventually be turned into a function that I implement in my Login Script
* Before checking for Python being installed, we can first find ITG records for params
    * This might also confirm that passwords match the params somehow so it's not as fragile. 
    * Then we use Rewst to standardize to our expected format. 

* My first idea is to use: Get-ITGluePasswords and some filters to try and match relevant passwords to a user.
* There doesn't really seem to be a good way to filter ATM.
    * Could be a limitation of the wrappers implmentation, need to test.

* Unlike my metascript for LAPS (which this is based) this won't need to run on the system. 
* Ended up using Password Category ID i think? 
7.22.25 - Dillon Daniel
#>

<#
param(
[Parameter(Position=1,Mandatory=$False)]
[Uri]  $ITGlueAPIEndpoint = 'https://api.itglue.com',
[Parameter(Position=2,Mandatory=$True)]
[String] $ITGlueAPIKey,
[Parameter(Position=3,Mandatory=$False)]
[String] $OrgID,
[Parameter(Position=4,Mandatory=$True)]
[String] $Username,
[Parameter(Position=5,Mandatory=$False)]
[Media(DefaultMediaId = 621, DefaultMediaType = 1)]$LoginFrameworkZip
)
#>

<#
#Import Immy ITG API. 
Import-Module ITGlueAPI
Add-ITGlueBaseURI -base_uri 'https://api.itglue.com'
Add-ITGlueAPIKey -Api_key $ITGlueAPIKey
# TESTING
#$output = Get-ITGluePasswordCategories -filter_name 'TEST' 
$output = Get-ITGluePasswords -organization_id $OrgID -page_size 1000 #-page_number 1 -page_size 100 # just going to brute force this but you could filter: -filter_password_category_id 520333

#filter down the records locally

$matches = $output.data |
    Where-Object { $_.attributes.username -ieq $Username }

$matchCount = $matches.Count

# all password records in ITG have a username, this will be my critera for now, but this can likely be adjusted too
Write-Host "Found $matchCount record(s) for username '$Username'."

if ($matchCount -gt 0) {
    # 3) List their names (you can use these later to fetch full details)
    foreach ($rec in $matches) {
        Write-Host "`t– $($rec.attributes.name)"
    }
} else {
    Write-Host "There were no records for the username provided..."
    Write-Host "Script exiting."
    return $false
}

 ====================================================================================================== 
* at this point, the script has outputted up to 1000 records for the given tenant, one layer of search
* I don't want it transmitting 1000 passwords every call though
* next step: the username specified in the parameters, is used to search those records, and get the exact name of the records
* this much smaller list can be piped back into an API search which can match by exact name, and pull the password, exposing much less
* ======================================================================================================


$finalResults = foreach ($rec in $matches) {
    # 1) Figure out the record ID
    #    The wrapper sets .id on show responses, but index responses only have the URL:
    $recordId = if ($rec.id) {
        $rec.id
    } else {
        # fallback: parse the numeric ID out of resource-url
        ([regex]::Match($rec.'resource-url','/passwords/(?<i>\d+)$')).Groups['i'].Value
    }

    # 2) Fetch the single record with its password
    $detail = Get-ITGluePasswords `
      -organization_id $OrgID `
      -id               $recordId `
      -show_password $True

    # 3) Extract the password field
    $pwd = $detail.data.attributes.password

    # 4) Emit a plain PSObject (constrained‑mode friendly)
    New-Object -TypeName PSObject -Property @{
        Name     = $rec.attributes.name
        Username = $rec.attributes.username
        Password = $pwd
    }
}

# 5) Display or return them
$finalResults | Format-Table -AutoSize
# ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++#
#>
# 0. Configuration
# Worth noting that Zip files are pre extracted to a file path that matches, just drop the .zip and access your files.
Write-Host "-------------------------------------------------"
$LoginFrameworkZip | Format-List *
$workingDir = 'C:\Temp\LoginAutomation'

#$MetaSessionENVVariable=Invoke-ImmyCommand -context System -ScriptBlock { return $env }
#Write-Host "MetaSessionVar: $($MetaSessionENVVariable)"

Invoke-ImmyCommand -IncludeLocals {
    
    $toolsDir    = 'C:\Tools\Sysinternals'
    $psExecPath  = Join-Path $toolsDir 'PsExec.exe'
    $downloadUrl = 'https://download.sysinternals.com/files/PSTools.zip'
    $tempZip     = Join-Path $env:TEMP 'PSTools.zip'

    $extractTo = 'C:\Temp\LoginAutomation'
    # Write-Host "Resolved Script Root: $PSScriptRoot"
    Expand-Archive -Path $using:LoginFrameworkZip -DestinationPath $using:workingDir -Force
    $zipFile = Get-ChildItem -Path "C:\Temp\LoginAutomation" -Filter *.zip | Select-Object -First 1

    if ($zipFile) {
        $extractedGoodies = $zipFile.Directory.FullName
        Expand-Archive -Path $zipFile.FullName -DestinationPath $zipFile.Directory.FullName -Force
        Remove-Item -Path $zipFile.FullName -Force  # optional: delete zip after extract
    } else {

    Write-Host "No zip file found, you probably forgot to zip your zip file, homie ;)"
    }
    #sleep 5
    Write-Host "Extracted Goodies: $extractedGoodies"
    # Path to Python on your endpoints
    #This script is basically doing a double unzip above -- this is an immy task specific thing
    # Once that takes place, we need to go inside my folder (why they tell you to just zip files but i had a folder structure to preserve)
    $extractedRoot = Get-ChildItem -Path $extractedGoodies -Directory | Select-Object -First 1
    $extractedRoot

    if (-not $extractedRoot) {
        Write-Error "No extracted folder found in $workingDir."
        exit 1
    }

    # Compose the path to the apps folder
    # The script works by calling this apps folder and selecting the relevant script, for the time being, eventually will accept dynamic params
    $appsPath = Join-Path $extractedRoot.FullName 'Apps'

    if (-not (Test-Path $appsPath)) {
        Write-Error "'Apps' folder not found in extracted directory."
        exit 1
    }

# Set your script path (e.g., manually passed in zoom.py)
    $targetScript = 'zoom.py'  # Replace or parametrize as needed
    $scriptPath = Join-Path $appsPath $targetScript

    if (-not (Test-Path $scriptPath)) {
    Write-Error "Script $targetScript not found in $appsPath"
    exit 1
    }

    Write-Host "Resolved script path: $scriptPath"
    
    $pythonExe   = 'C:\Program Files\Python314\python.exe'

    # Locate this PS1’s folder (where RMM should have staged autokey.py)
    #Write-Host "Value of MyInvocation =" $MyInvocation
    #$MyInvocation.BoundParameters | Format-List *
    #$scriptPath  = Join-Path $PSScriptRoot 'zoom.py'
    #$path2Python = 
    #Write-Host "Resolved script directory: $scriptDir"
    #Write-Host "Resolved script path:      $scriptPath"
    
    # 1. Ensure the automation script is present
    if (-not (Test-Path $scriptPath)) {
        Write-Error "Automation script not found at `$scriptPath`. Make sure zoom.py is uploaded alongside this PS1."
        exit 1
    }

    # 2. Ensure Sysinternals folder exists
    if (-not (Test-Path $toolsDir)) {
        Write-Host "Staging PSExec Folder: $toolsDir"
        New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null
    }

    # 3. Download & extract PsExec if missing
    if (-not (Test-Path $psExecPath)) {
        Write-Host "PsExec not found. Downloading PSTools…"
        Invoke-WebRequest -Uri $downloadUrl -OutFile $tempZip -UseBasicParsing
        Expand-Archive -Path $tempZip -DestinationPath $toolsDir -Force
        Remove-Item $tempZip
        Write-Host "PsExec deployed to $psExecPath"
    }

    # 4. Launch the Python automation script interactively in session 1
    #    -accepteula auto-accepts the Sysinternals EULA
    #    -i 1        runs in the console (user’s) session
    #    -w          sets the working-directory so relative paths resolve correctly
    Write-Host "Launching automation script in interactive session…"
    & $psExecPath -accepteula -i 1 -w $appsPath `
        "$pythonExe" "$scriptPath"
}

#"C:\Temp\LoginAutomation\Dynamic_App_Login_Framework\Apps\zoom.py"