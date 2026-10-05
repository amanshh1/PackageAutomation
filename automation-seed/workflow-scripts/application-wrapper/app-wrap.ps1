[CmdletBinding()]
param(
[Parameter(Mandatory)]
[string]$SearchApp = "7-zip",
[Parameter(Mandatory)]
[string]$AppID,
[string]$RegistryJson
)
# Find all winget.exe under WindowsApps
          $paths = Get-ChildItem "C:\Program Files\WindowsApps" -Directory `
              | Where-Object { $_.Name -like "Microsoft.DesktopAppInstaller_*" } `
              | ForEach-Object { Join-Path $_.FullName "winget.exe" } `
              | Where-Object { Test-Path $_ }
          # If no winget found, fail the workflow
          if ($paths.Count -eq 0) {
              Write-Error "No winget.exe found on this system."
              exit 1
          }
          # Sort by version & pick the newest
          $Winget = $paths |
              Sort-Object {
                  # Extract version number from folder name segment 2
                  ($_ -split "_")[1]
              } -Descending |
              Select-Object -First 1
       

# Search Application with native PowerShell execution and UTF-8 encoding
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
#$command = "& '$Winget' show '$SearchApp' --source winget --accept-source-agreements"
$command = "& '$Winget' show '$AppID' --source winget --accept-source-agreements"
$info = Invoke-Expression $command | Out-String
Write-Host $info

# Filter out progress bars, empty lines, and non-relevant output
$info = $info -replace 'â–ˆ+.*MB', '' -replace '\s+\\s+', '' -replace ' progress bar patterns like \d+\.\d+ MB', ''
$lines = $info -split "`n" |
    Where-Object {
        $_.Trim() -ne '' -and
        $_ -notmatch '^\s*[-=|]+\s*$' -and
        $_ -notmatch '^\s*\d+(\.\d+)?\s*MB\s*/\s*\d+(\.\d+)?\s*MB\s*$' -and
        $_ -notmatch '^[â–ˆ]+\s*\d+(\.\d+)?\s*MB\s*/\s*\d+(\.\d+)?\s*MB\s*$'
    }

$foundLine = $lines | Where-Object { $_ -match 'Found\s+(.+?)\s*\[\s*(\S+?)\s*\]' }
Write-Host $foundLine
if (-not $foundLine) {
    Write-Error "No matching package found for '$SearchApp'"
    exit 1
}

$name = ($foundLine -replace 'Found\s+(.+?)\s*\[\s*(\S+?)\s*\].*', '$1').Trim()
$id   = ($foundLine -replace 'Found\s+(.+?)\s*\[\s*(\S+?)\s*\].*', '$2').Trim()

$versionLine   = $lines | Where-Object { $_ -match '^Version:\s*(.+)$' }
$version       = if ($versionLine)   { ($versionLine   -replace '^Version:\s*(.+)$', '$1').Trim() } else { '' }

$publisherLine = ($lines -join "`n") -match '(?ms)^Publisher:\s*(.*?)(?=^\S[^:\r\n]*:\s*|\z)'
$publisher = if ($publisherLine) { $Matches[1].Trim() -replace '\s+', ' ' } else { '' }

$descriptionLine = ($lines -join "`n") -match '(?ms)^Description:\s*(.*?)(?=^\S[^:\r\n]*:\s*|\z)'
$description     = if ($descriptionLine) { $Matches[1].Trim() -replace '\s+', ' ' } else { '' }

Write-Host "-----Application-Info---------"
Write-Host $publisher
Write-Host $version
Write-Host $name
Write-Host $id
Write-Host $description
Write-Host "-----Info-End-Here---------"
# Define new values

#$filePath = ".\scripts\Deployment\Deploy-Application.ps1"
#$filePath = "$env:GITHUB_WORKSPACE\PackageAutomation\automation-seed\baseline-scripts\DeploymentScriptFile\Deploy-Application.ps1"
$filePath = Join-Path $env:GITHUB_WORKSPACE "automation-seed/baseline-scripts/DeploymentScriptFile/Deploy-Application.ps1"
$newValues = @{
    'appVendor'        = $publisher
    'appName'          = $SearchApp
    'appVersion'       = $version
    'appArch'          = 'x64'
    'appLang'          = 'EN'
    'appRevision'      = '02'
    'appScriptVersion' = '2.0.0'
    'appScriptDate'    = (Get-Date).ToString('dd/MM/yyyy')
    'appScriptAuthor'  = 'Github-Intune-Automation'
    'WingetId'         = $id
    'Description'      = $description 
}

# Read file content
$content = Get-Content -Path $filePath

for ($i = 0; $i -lt $content.Count; $i++) {
    foreach ($key in $newValues.Keys) {
        # Build regex dynamically and escape $
        $pattern = "\`$$key\s*="
        if ($content[$i] -match $pattern) {
            # Replace only the value inside single quotes
            $content[$i] = $content[$i] -replace "(?<=\=\s*')[^']*(?=')", $newValues[$key]
        }
    }
}

# Write updated content back to file
Set-Content -Path $filePath -Value $content

Write-Host "Variables updated successfully in $filePath"

if($RegistryJson -ne $null){
    $RegistryList = $RegistryJson | ConvertFrom-Json

    $Output = '$RegistryList = @(' + "`r`n"
    foreach ($reg in $RegistryList) {
        $Output += "    @{" + "`r`n"
        $Output += "        Path  = '" + $reg.Path + "'" + "`r`n"
        $Output += "        Name  = '" + $reg.Name + "'" + "`r`n"
        $Output += "        Value = '" + $reg.Value + "'" + "`r`n"
        $Output += "        Type  = '" + $reg.Type + "'" + "`r`n"
        $Output += "    }," + "`r`n"
    }
    $Output = $Output.TrimEnd(",`r`n") + "`r`n)"


    $ScriptContent = Get-Content -Path $filePath -Raw

    # Replace marker
    $UpdatedContent = $ScriptContent -replace '#\{Apply-Registry-Section\}', $Output

    # Write back to file
    Set-Content -Path $filePath -Value $UpdatedContent

    Write-Host "Updated PowerShell script successfully!"

    # Publish values as GitHub Actions step outputs
    if (-not [String]::IsNullOrWhiteSpace($env:GITHUB_OUTPUT)) {
           "publisher=$publisher" | Out-File -FilePath $env:GITHUB_OUTPUT -Encoding utf8 -Append
           "description=$description" | Out-File -FilePath $env:GITHUB_OUTPUT -Encoding utf8 -Append
           Write-Host "Application details published to GITHUB_OUTPUT."
    }
    else {
        Write-Warning "GITHUB_OUTPUT is not available. GitHub step outputs were not created."
    }
}
