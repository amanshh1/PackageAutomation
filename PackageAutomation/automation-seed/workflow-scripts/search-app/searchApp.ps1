<#
.SYNOPSIS
    Searches Intune for an application by display name and returns metadata.
.DESCRIPTION
    Uses Microsoft Graph v1.0 API to query Intune mobileApps.
    Requires that `azure/login@v2` has already authenticated 
    and MS Graph token is available via federated identity.

.PARAMETER AppName
    The display name of the Intune application.

.EXAMPLE
    ./searchApp.ps1 -AppName "Google Chrome"
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$AppName,
    [Parameter(Mandatory = $false)]
    [string]$DepApp,
    [String]$Message=""
)

# --------------------------------------------------------------------
# Retrieve token from Azure Login session (GitHub OIDC)
# --------------------------------------------------------------------
try {
    $token = az account get-access-token --resource-type ms-graph --query accessToken -o tsv
} catch {
    Write-Error "Unable to fetch MS Graph token. Ensure azure/login step succeeded."
    exit 1
}

$Headers = @{
    Authorization = "Bearer $token"
    "Content-Type" = "application/json"
}

$EOF = [System.Guid]::NewGuid().ToString()
function Get-IntuneMobileApp {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$AppName,

        [Parameter(Mandatory = $true)]
        [hashtable]$Headers
    )

    Write-Host "Searching Intune for application: $AppName"
    # Escape single quotes in the app name to prevent OData filter errors
    $encodedName = [System.Net.WebUtility]::UrlEncode($AppName)
    if($null -ne $encodedName -and $encodedName -ne "" -and $encodedName -ne "Undefined"){

    # Construct the Graph URL
    $graphUrl = "https://graph.microsoft.com/v1.0/deviceAppManagement/mobileApps?`$filter=startswith(displayName,'$encodedName')"

    Write-Host "Querying Graph: $graphUrl"

    try {
        # Using -ErrorAction Stop ensures that any failure jumps straight to the catch block
        $response = Invoke-RestMethod -Uri $graphUrl -Headers $Headers -Method GET -ErrorAction Stop
    } catch {
        Write-Error "Graph API request failed. $($_.Exception.Message)"
        # Throw terminates the function and passes the error up to the caller instead of killing the whole script
        throw "Failed to query Graph API for application: $AppName" 
    }
    }

    if (-not $response.value -or $response.value.Count -eq 0) {
        Write-Warning "No Intune application found matching '$AppName'"
        return $null
    }

    # Return the app result(s)
    Write-Host $response.value
    return $response.value
}
# --------------------------------------------------------------------
# Query Intune for mobileApps using Graph v1.0
# --------------------------------------------------------------------

$allapp = Get-IntuneMobileApp -Headers $Headers -AppName $AppName

# --------------------------------------------------------------------
# Prioritize exact match
# --------------------------------------------------------------------

    if ($null -ne $allapp) {
        # --------------------------------------------------------------------
        # Prioritize exact match
        # --------------------------------------------------------------------
        $app = $allapp | Where-Object { $_.displayName -eq $AppName } | Select-Object -First 1

        # Fallback to first partial match
        # FIX: Changed $response.value to $allapp
        if (-not $app) {
            $app = $allapp | Select-Object -First 1
        }

        # --------------------------------------------------------------------
        # Output results
        # --------------------------------------------------------------------
        # FIX: Only print if $app actually has data
        if ($app) {
            Write-Host "`n===== APPLICATION FOUND ====="
            Write-Host "Name:        $($app.displayName)"
            Write-Host "ID:          $($app.id)"
            Write-Host "Description: $($app.description)"
            Write-Host "Notes:       $($app.notes)"
            Write-Host "Publisher:   $($app.publisher)"
            Write-Host "Created:     $($app.createdDateTime)"
            Write-Host "Updated:     $($app.lastModifiedDateTime)"
            Write-Host "=====================================`n"
        }
        
            if ($null -ne $app.id){
            "app_id_exist=true" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
            "app_id=$($app.id)" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
            "app_name=$($app.displayName)" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
            "app_created=$($app.createdDateTime)" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
            "app_Updated=$($app.lastModifiedDateTime)" | Out-File -FilePath $env:GITHUB_OUTPUT  -Append -Encoding utf8
            $app_id_exist =$true
            $proceed="false"
            $Message+= "${AppName} Application Details`n"
            $Message+= "Application Name:$($app.displayName) `n"
            $Message+= "Application ID:$($app.id) `n"
        }
            else{
                    "app_id_exist=false" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
                    $Message+="$($AppName) doesn't exist"
                }

    } else {
        "app_id_exist=false" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
        $app_id_exist =$false
        $proceed="true"
        #Write-Warning "Script stopped: No applications were returned from the search."
         
    }
# Cheching for Dependent App
if($DepApp){
    
    $allapp = Get-IntuneMobileApp -Headers $Headers -AppName $DepApp
    if ($allapp) {
        # --------------------------------------------------------------------
        # Prioritize exact match
        # --------------------------------------------------------------------
        $app = $allapp | Where-Object { $_.displayName -eq $DepApp } | Select-Object -First 1

        # Fallback to first partial match
        # FIX: Changed $response.value to $allapp
        if (-not $app) {
            $app = $allapp | Select-Object -First 1
        }

        # --------------------------------------------------------------------
        # Output results
        # --------------------------------------------------------------------
        # FIX: Only print if $app actually has data
        if ($app) {
            "dep_app_exist=true" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
            "dep_app_id=$($app.id)" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
            $dep_app_exist = $true
            $Message+= "=====================================`n"
            
            $Message+= "Dependent Application Detail`n"
            $Message+= "Application Name:$($app.displayName) `n"
            $Message+= "Application ID:$($app.id) `n"
        }
    } else {
        "dep_app_exist=false" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
        $dep_app_exist = $false
        $Message+="`n Dependent Application $($DepApp) not found."
        Write-Warning "S\cript stopped: No applications were returned from the search."
    }

    if($app_id_exist -eq $false -and $dep_app_exist -eq $true){
        $proceed="true"
    }
    else { $proceed="false"}
}

if ($proceed -eq 'true') {
    "proceed=true" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
}
else {
    "proceed=false" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
}

@"
message<<$EOF
$Message
$EOF
"@ | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8

exit 0