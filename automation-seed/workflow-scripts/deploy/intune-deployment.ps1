<#
.SYNOPSIS
Create & upload a Win32LobApp to Intune via Microsoft Graph and optionally assign it.

.DESCRIPTION
Flow:
1) POST /deviceAppManagement/mobileApps (create Win32LobApp)
2) POST /mobileApps/{id}/contentVersions (create version)
3) POST /contentVersions/{ver}/files (create file record -> SAS URL)
4) PUT to SAS URL (upload .intunewin)
5) POST /files/{fileId}/commit (commit with fileEncryptionInfo)
6) Poll until uploadState = commitFileSuccess
7) (Optional) POST /mobileApps/{id}/assign

Requires:
- Azure CLI login (az login) and correct Graph permissions (e.g., DeviceManagementApps.ReadWrite.All).
- Intune license for the identity running the calls.
#>

[CmdletBinding()]
param(
    
    [string]$IntuneWinPath = "f:\y\s.intunewin",

    [Parameter(Mandatory)]
    [string]$AppName,
    [string]$AppLogo,
    [string]$Publisher = "Custom App",
    [string]$Description = "Deployed via GitHub Actions, As part of AppLifeCycle Automation Deployment of Winget Package only",
    [string]$InstallCmd = "setup.exe /silent",
    [string]$UninstallCmd = "setup.exe /uninstall /silent",
    [string]$DependentAppId,
    [string]$GroupId, # Azure AD group ID for assignment (optional)
    [ValidateSet('available', 'required', 'uninstall', 'notApplicable')]
    [string]$Intent = "available",
   
    # Optional explicit setup file path (path inside the .intunewin payload)
    [string]$SetupFilePath,

    # Optional: path to a JSON file that contains fileEncryptionInfo (recommended for CI).
    [string]$EncryptionInfoPath,

    # Detection rule settings
    [string]$DetectionPath = "%ProgramFiles%",
    [string]$DetectionFile = "YourApp.exe"
)

#region Helpers
function Write-Info { param([string]$m) Write-Host "[INFO ] $m" -ForegroundColor Cyan }
function Write-Warn { param([string]$m) Write-Host "[WARN ] $m" -ForegroundColor Yellow }
function Write-Err { param([string]$m) Write-Host "[ERROR] $m" -ForegroundColor Red }

function Get-GraphToken {
    $tok = az account get-access-token --resource-type ms-graph | ConvertFrom-Json
    if (-not $tok.accessToken) { throw "Failed to get Graph access token via Azure CLI." }
    return $tok.accessToken
}

function New-GraphHeaders {
    param([string]$Token)
    return @{
        "Authorization" = "Bearer $Token"
        "Content-Type"  = "application/json"
    }
}

function GraphHeaders {
    param(
        [Parameter(Mandatory)][string]$Token
    )
    return @{
        "Authorization" = "Bearer $Token"
        "Content-Type"  = "application/json"
        "Accept"        = "application/json"
    }
}


function Resolve-IntuneWinFile {
    param([Parameter(Mandatory)][string]$PathSpec)
    $file = Get-ChildItem -Path $PathSpec -ErrorAction Stop | Select-Object -First 1
    if (-not $file) { throw "No .intunewin file matched: $PathSpec" }
    return $file.FullName
}


function Invoke-Graph {
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'POST', 'PATCH', 'DELETE')]
        [string]$Method,
        [Parameter(Mandatory)][string]$Uri,
        [hashtable]$Headers,
        [string]$Body
    )
    try {
        if ($PSBoundParameters.ContainsKey('Body')) {
            $resp = Invoke-RestMethod -Method $Method -Uri $Uri -Headers $Headers -Body $Body
        }
        else {
            $resp = Invoke-RestMethod -Method $Method -Uri $Uri -Headers $Headers
        }
        return $resp
    }
    catch {
        $status = $_.Exception.Response.StatusCode.value__
        Write-Err "Graph call failed ($Method $Uri). HTTP $status"
        try {
            $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
            $errBody = $reader.ReadToEnd()
            Write-Host $errBody
        }
        catch {}
        throw
    }
}

function Get-GraphMobileAppContentFile {
    param([string]$AppId, [string]$VerId, [string]$FileId, [hashtable]$Headers)

    $uri = "https://graph.microsoft.com/v1.0/deviceAppManagement/mobileApps/$AppId/microsoft.graph.win32LobApp/contentVersions/$VerId/files/$FileId"
    return Invoke-RestMethod -Method GET -Headers $Headersgraph -Uri $uri
}

# -------------------------
# Commit file to Intune
# -------------------------
function Invoke-GraphCommit {
    param(

            [Parameter(Mandatory)]
            [string]$AppId, 
            
            [string]$IntuneWinPath,

            [Parameter(Mandatory)] 
            [string]$VerId, 

            [Parameter(Mandatory)] 
            [string]$FileId, 

            [Parameter(Mandatory)] 
            [hashtable]$Headers,

            [Parameter(Mandatory)]
            [PSCustomObject]$Data

    )

    $uri = "https://graph.microsoft.com/v1.0/deviceAppManagement/mobileApps/$appId/microsoft.graph.win32LobApp/contentVersions/$VerId/files/$FileId/commit"
    <#
    if (-not (Test-Path -LiteralPath $IntuneWinPath)) {
        throw "IntuneWin file not found: $IntuneWinPath"
    }
#>
    
    try {


            $EncryptionKeyBase64 = $Data.EncryptionKeyBase64
            $MacKeyBase64 = $Data.MacKeyBase64
            $InitializationVectorBase64 = $Data.InitializationVectorBase64
            $MacBase64 = $Data.MacBase64
            $FileDigestBase64 = $Data.FileDigestBase64
            $ProfileIdentifier = $Data.ProfileIdentifier
            $FileDigestAlgorithm = $Data.FileDigestAlgorithm

            Write-Host "`n $($EncryptionKeyBase64) `n $($MacKeyBase64) `n $($InitializationVectorBase64) `n $($MacBase64) `n $($FileDigestBase64) `n $($FileDigestBase64) "

            # 3) Validate byte lengths (optional but recommended)
            function LenB64([string]$s) {
                if (-not $s) { return 0 }
                ([Convert]::FromBase64String($s)).Length
            }

            Write-Info ("encryptionKey bytes:        {0}" -f (LenB64 $EncryptionKeyBase64))
            Write-Info ("macKey bytes:               {0}" -f (LenB64 $MacKeyBase64))
            Write-Info ("initializationVector bytes: {0}" -f (LenB64 $InitializationVectorBase64))
            Write-Info ("mac bytes:                  {0}" -f (LenB64 $MacBase64))
            Write-Info ("fileDigest bytes:           {0}" -f (LenB64 $FileDigestBase64))

            if ((LenB64 $EncryptionKeyBase64) -ne 32) { throw "encryptionKey must be 32 bytes" }
            if ((LenB64 $MacKeyBase64) -ne 32) { throw "macKey must be 32 bytes" }
            if ((LenB64 $MacBase64) -ne 32) { throw "mac must be 32 bytes" }
            if ((LenB64 $FileDigestBase64) -ne 32) { throw "fileDigest must be 32 bytes" }
            if ((LenB64 $InitializationVectorBase64) -ne 16) { throw "initializationVector must be 16 bytes" }

            # 4) Build commit body (to use in your Graph commit call)
            $fileEncryptionInfoBody = [ordered]@{
                fileEncryptionInfo = [ordered]@{
                    "@odata.type"        = "#microsoft.graph.fileEncryptionInfo"
                    encryptionKey        = $EncryptionKeyBase64
                    macKey               = $MacKeyBase64
                    initializationVector = $InitializationVectorBase64
                    mac                  = $MacBase64
                    profileIdentifier    = $ProfileIdentifier           # "ProfileVersion1"
                    fileDigest           = $FileDigestBase64
                    fileDigestAlgorithm  = $FileDigestAlgorithm         # "SHA256"
                }
            }

            # Output as object and as JSON (for debugging / direct use)
            Write-Info "fileEncryptionInfo object ready for commit body:"
            $fileEncryptionInfoBody | Format-List -Force

            $json = $fileEncryptionInfoBody | ConvertTo-Json -Depth 6 -Compress
            Write-Info "JSON (commit body fragment):"
            Write-Output $json

   
           

    }
    catch {
            Write-Err $_.Exception.Message
            throw
    }
           
    

    $commitBody = $fileEncryptionInfoBody
    Write-Host $fileEncryptionInfoBody
    #$commitBody = $encInfo.FileEncryptionInfoObject
    Write-Host "Before GetBytes reached 1"
    $utf8Bytes = [System.Text.Encoding]::UTF8.GetBytes(($commitBody | ConvertTo-Json -Depth 6 -Compress))

    try {
            # $resp = Invoke-RestMethod -Method POST -Headers $Headers -Uri $uri -Body $body -ContentType 'application/json'
            $resp = Invoke-RestMethod -Method POST -Headers $Headers -Uri $uri `
                -Body $utf8Bytes -ContentType "application/json; charset=utf-8"
            if ($null -eq $resp) { Write-Host "Commit is successfull" }

    }
    catch [System.Net.WebException] {
            $statusCode = $_.Exception.Response.StatusCode.Value__
            $respStream = $_.Exception.Response.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($respStream)
            $reader.BaseStream.Position = 0
            $responseBody = $reader.ReadToEnd()
            Write-Host "Status: $statusCode"
            Write-Host "Body:"
            Write-Host $responseBody
    }
        # On success, Graph returns 204 No Content (Invoke-RestMethod returns $null)
        Write-Host "Graph commit submitted (expecting 204 No Content)."

}


# -------------------------
# Upload file in blocks
# -------------------------

function Send-BlobInBlocks {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SasUrl,

        [Parameter(Mandatory)]
        [string]$FilePath,

        #[ValidateRange(1, 4000)]
        [int]$ChunkSizeMB = 4  # Default 4 MB; Azure supports much larger, but 4–10 MB is typical
    )

    # Validate inputs
    if (-not (Test-Path -LiteralPath $FilePath)) {
        throw "File not found: $FilePath"
    }

    $chunkSize = $ChunkSizeMB * 1MB
    $fi = Get-Item -LiteralPath $FilePath
    $total = [int64]$fi.Length
    Write-Host "Uploading '$($fi.Name)' ($total bytes) via Put Block ($ChunkSizeMB MB chunks)..."

    # Use a strongly-typed list for block IDs
    $blockIds = New-Object System.Collections.Generic.List[string]

    # Open file stream for efficient reads
    $fs = [System.IO.File]::Open($FilePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)

    # Azure recommends sending x-ms-version; not strictly required for SAS, but good practice
    $baseHeaders = @{
        "x-ms-version" = "2020-12-06"
    }

    try {
        $index = 0
        $offset = 0L

        while ($offset -lt $total) {
            $remaining = $total - $offset
            $size = [Math]::Min($chunkSize, $remaining)
            $buffer = New-Object byte[] $size

            $bytesRead = $fs.Read($buffer, 0, $size)
            if ($bytesRead -le 0) { break }

            # Prefer the "block-00000000" pattern for Intune scenarios to match common implementations
            $idPlain = "block-{0:D8}" -f $index
            Write-Host "Before GetBytes reached 2"
            $blockId = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($idPlain))
            $blockIds.Add($blockId)

            # Build block URI (MUST use literal '&' not '&amp;')
            if ($SasUrl.Contains("?")) {
                $blockUri = "$SasUrl&comp=block&blockid=$([System.Web.HttpUtility]::UrlEncode($blockId))"
            }
            else {
                $blockUri = "$SasUrl?comp=block&blockid=$([System.Web.HttpUtility]::UrlEncode($blockId))"
            }

            # PUT block (application/octet-stream, raw bytes). Content-Length is set automatically.
            Invoke-RestMethod -Method Put -Uri $blockUri -Headers $baseHeaders -ContentType "application/octet-stream" -Body $buffer

            Write-Host ("  Block {0} ({1} bytes) uploaded." -f $idPlain, $bytesRead)
            $offset += $bytesRead
            $index++
        }

        # Commit block list
        Write-Host "Committing block list..."
        $commitUri = if ($SasUrl.Contains("?")) { "$SasUrl&comp=blocklist" } else { "$SasUrl?comp=blocklist" }

        # IMPORTANT: Use <Latest> elements (do not use <LatestBlock>)
        $blockListXml = "<BlockList>" + ($blockIds | ForEach-Object { "<Latest>$_</Latest>" }) + "</BlockList>"

        Invoke-RestMethod -Method Put -Uri $commitUri -Headers $baseHeaders -ContentType "application/xml" -Body $blockListXml

        Write-Host "Block list committed successfully."

        # Verify blob size with HEAD (use Invoke-WebRequest to read headers)
        
        # Verify blob size with HEAD
        try {
            $iwParams = @{
                Method  = 'Head'
                Uri     = $SasUrl
                Headers = $baseHeaders
            }
            if ($PSVersionTable.PSVersion.Major -lt 6) { $iwParams.UseBasicParsing = $true }
            $head = Invoke-WebRequest @iwParams
            $blobSize = $head.Headers['Content-Length']
            Write-Host "Azure blob size (server-reported): $blobSize bytes"
        }
        catch {
            Write-Warning "HEAD check failed: $($_.Exception.Message). Falling back to .NET HttpClient..."
            # Fallback to Option B
            $handler = New-Object System.Net.Http.HttpClientHandler
            $client = New-Object System.Net.Http.HttpClient($handler)
            foreach ($k in $baseHeaders.Keys) { $client.DefaultRequestHeaders.Remove($k); $client.DefaultRequestHeaders.Add($k, $baseHeaders[$k]) }

            $request = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Head, $SasUrl)
            $response = $client.SendAsync($request).GetAwaiter().GetResult()
            if (-not $response.IsSuccessStatusCode) {
                throw "HEAD request failed: $([int]$response.StatusCode) $($response.ReasonPhrase)"
            }

            $blobSize = $response.Content.Headers.ContentLength
            if (-not $blobSize -and $response.Headers.Contains('Content-Length')) {
                $blobSize = ($response.Headers.GetValues('Content-Length') | Select-Object -First 1)
            }
            $client.Dispose()
            Write-Host "Azure blob size (server-reported): $blobSize bytes"
        }

    }
    finally {
        $fs.Dispose()
    }

    return $blockIds

}

# ------------------------------------------------
# Extract .IntuneWinfile (XML) & IntunePackage
# ------------------------------------------------

function Get-EncryptedData {
    
    [CmdletBinding()]
    param(
    
        [Parameter(Mandatory)]
        [string]$appName,

        [Parameter(Mandatory)]
        [boolean]$CommitSuccess
    )

        #$IntuneWinPath = Join-Path $env:GITHUB_WORKSPACE "automation-seed\baseline-scripts\IntuneDeploymentPackage\${appName}\${appName}.intunewin"
        $IntuneWinPath= "D:\a\PackageAutomation\PackageAutomation\package\${appName}.intunewin"
        $tempDir = "D:\a\PackageAutomation\PackageAutomation\package\${appName}\Extracted"

    if ($CommitSuccess -eq $true) {
        if (-not (Test-Path $tempDir)) {
            break
        }

        Remove-Item -Path $tempDir -Recurse -force
        Write-Host "Temp file cleared post successfull commit"
    
    }
    else {

        if (-not (Test-Path $tempDir)) {
            New-Item -ItemType Directory -Path $tempDir
    
        }

        Write-Host "Copying .intunewin as ZIP to temp..."
        $zipPath = Join-Path $tempDir "package.zip"
        Copy-Item -LiteralPath $IntuneWinPath -Destination $zipPath -Force

        Write-Host "Expanding archive..."
        Expand-Archive -Path $zipPath -DestinationPath $tempDir -Force

        # Find ApplicationInfo.xml anywhere under the extracted tree
        $appInfo = Get-ChildItem -Path $tempDir -Recurse -Filter "Detection.xml" | Select-Object -First 1
        if (-not $appInfo) {
            throw "ApplicationInfo.xml not found inside $IntuneWinPath."
        }
        Write-Info "Found ApplicationInfo.xml at: $($appInfo.FullName)"

        $appData = Get-ChildItem -Path $tempDir -Recurse -Filter "*.intunewin" | Select-Object -First 1
        if (-not $appData) {
            throw "Application package not found."
        }
        Write-Info "Found Application package $($appData.FullName)"


        # Save to requested output path
        $outDir = Split-Path -Parent $appInfo.FullName
       # $ApplicationInfoXmlPath = "C:\NewRunner\actions-runner\_work\Test-Action\IntuneDeploymentPackage\7-Zip\Extracted\IntuneWinPackage\Metadata\Detection.xml"
        $ApplicationInfoXmlPath = $appInfo.FullName
        if (-not (Test-Path -LiteralPath $outDir)) {
            New-Item -ItemType Directory -Path $outDir -Force | Out-Null
        }
        # Copy-Item -LiteralPath $appInfo.FullName -Destination $ApplicationInfoXmlPath -Force
        Write-Info "ApplicationInfo.xml exported to: $ApplicationInfoXmlPath"

        # 2) Read EncryptionInfo from ApplicationInfo.xml
        [xml]$xml = Get-Content -LiteralPath $ApplicationInfoXmlPath -Raw

        $enc = $xml.ApplicationInfo.EncryptionInfo
        $IntuneWinFile = Get-ChildItem -Path $tempDir -Recurse -Filter "*.intunewin" | Select-Object -First 1
    
        $IntuneEncData = [PSCustomObject]@{
            UnencryptedFileSize        = $xml.ApplicationInfo.UnencryptedContentSize
            FileName                   = $xml.ApplicationInfo.FileName
            EncryptionKeyBase64        = $enc.EncryptionKey
            MacKeyBase64               = $enc.MacKey
            InitializationVectorBase64 = $enc.InitializationVector
            MacBase64                  = $enc.Mac
            FileDigestBase64           = $enc.FileDigest
            ProfileIdentifier          = $enc.ProfileIdentifier
            FileDigestAlgorithm        = $enc.FileDigestAlgorithm
            IntuneWinPackageSize       = $IntuneWinFile.Length
            IntuneWinFilePath          = $appData.FullName
        }

    }

    return $IntuneEncData
    
}

# ------------------------------------------------
# Dependency Mapping 
# ------------------------------------------------

function Add-IntuneWin32AppDependency {

    param (
        [string]$AccessToken,
        [string]$MainAppId,
        [string]$DependentAppId
    )

    $uri = "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$MainAppId/updateRelationships"

    $headers = @{
        Authorization = "Bearer $AccessToken"
        "Content-Type" = "application/json"
    }

    # ✅ Correct JSON body for Graph
    $body = @{
        relationships = @(
            @{
                "@odata.type" = "#microsoft.graph.mobileAppDependency"
                targetId       = $DependentAppId
                dependencyType = "autoInstall"
            }
        )
    } | ConvertTo-Json -Depth 5

    Invoke-RestMethod -Method POST -Uri $uri -Headers $headers -Body $body
}
#---------------------------------------------------
$GraphToken = Get-GraphToken
$Headersgraph = New-GraphHeaders -Token $GraphToken
$Headers = GraphHeaders -Token $GraphToken


#--- Resolve .intunewin file ---
$resolvedFile = Resolve-IntuneWinFile -PathSpec $IntuneWinPath
$fileName = Split-Path -Path $resolvedFile -Leaf
$fileSize = (Get-Item -LiteralPath $resolvedFile).Length
Write-Info "Resolved .intunewin: $resolvedFile ($fileSize bytes)"


# Derive setupFilePath from InstallCmd if not given
if (-not $SetupFilePath -or -not $SetupFilePath.Trim()) {
    $SetupFilePath = ($InstallCmd -split '\s+', 2)[0]
    Write-Info "Inferred setupFilePath from InstallCmd: $SetupFilePath"
}


<# Check & load $applogo
    if (Test-Path $AppLogo) {
        $LogoBase64 = [Convert]::ToBase64String(
            [System.IO.File]::ReadAllBytes($AppLogo)
        )
    }
    else {
        $LogoBase64 = $AppLogo
    }
#>

# --- 1) Create COMPLETE Win32LobApp with all required properties ---
if($null -ne $LogoBase64 -and $LogoBase64 -ne "" -and $LogoBase64 -ne "undefined"){
    $appBodyObj = @{
    '@odata.type'                   = "#microsoft.graph.win32LobApp"
    displayName                     = $AppName
    description                     = $Description
    publisher                       = $Publisher
    fileName                        = $fileName  # Move up here
    setupFilePath                   = $SetupFilePath
    installCommandLine              = $InstallCmd
    uninstallCommandLine            = $UninstallCmd
    applicableArchitectures         = "x64"
    
      minimumSupportedOperatingSystem = @{
        '@odata.type' = "#microsoft.graph.windowsMinimumOperatingSystem"
        v10_0         = $true
    }
    largeIcon           = @{
    "@odata.type" = "microsoft.graph.mimeContent"
    type          = "image/png"
    value         = $LogoBase64
      }
    rules                           = @(
        @{
            "@odata.type"        = "#microsoft.graph.win32LobAppRegistryRule"
            ruleType             = "detection"
            keyPath              = "HKEY_LOCAL_MACHINE\SOFTWARE\Contoso\ServiceUI"
            valueName            = "Installed"
            operationType        = "exists"
            check32BitOn64System = $false
        }
    )
    installExperience               = @{
        '@odata.type' = "#microsoft.graph.win32LobAppInstallExperience"
        runAsAccount  = "system"
    }
    returnCodes                     = @(
        @{ '@odata.type' = "#microsoft.graph.win32LobAppReturnCode"; returnCode = 0; type = "success" }
        @{ '@odata.type' = "#microsoft.graph.win32LobAppReturnCode"; returnCode = 3010; type = "softReboot" }
    )
}
}
else{

    $appBodyObj = @{
    '@odata.type'                   = "#microsoft.graph.win32LobApp"
    displayName                     = $AppName
    description                     = $Description
    publisher                       = $Publisher
    fileName                        = $fileName  # Move up here
    setupFilePath                   = $SetupFilePath
    installCommandLine              = $InstallCmd
    uninstallCommandLine            = $UninstallCmd
    applicableArchitectures         = "x64"
    
      minimumSupportedOperatingSystem = @{
        '@odata.type' = "#microsoft.graph.windowsMinimumOperatingSystem"
        v10_0         = $true
    }
    rules                           = @(
        @{
            "@odata.type"        = "#microsoft.graph.win32LobAppRegistryRule"
            ruleType             = "detection"
            keyPath              = "HKEY_LOCAL_MACHINE\SOFTWARE\Contoso\ServiceUI"
            valueName            = "Installed"
            operationType        = "exists"
            check32BitOn64System = $false
        }
    )
    installExperience               = @{
        '@odata.type' = "#microsoft.graph.win32LobAppInstallExperience"
        runAsAccount  = "system"
    }
    returnCodes                     = @(
        @{ '@odata.type' = "#microsoft.graph.win32LobAppReturnCode"; returnCode = 0; type = "success" }
        @{ '@odata.type' = "#microsoft.graph.win32LobAppReturnCode"; returnCode = 3010; type = "softReboot" }
    )
}
}

$app = Invoke-Graph -Method POST -Uri "https://graph.microsoft.com/v1.0/deviceAppManagement/mobileApps" -Headers $Headersgraph -Body ($appBodyObj | ConvertTo-Json -Depth 12)
$appId = $app.id
Write-Info "Created COMPLETE app: $($app.displayName) (Id: $appId)"

# --- 2) Create content version (CORRECTED ENDPOINT) ---
$contentBody = @{ '@odata.type' = '#microsoft.graph.mobileAppContent' }
$ContentVersion = Invoke-Graph -Method POST -Uri "https://graph.microsoft.com/v1.0/deviceAppManagement/mobileApps/$appId/microsoft.graph.win32LobApp/contentVersions" -Headers $Headersgraph -Body ($contentBody | ConvertTo-Json)
$contentVersionId = $contentVersion.id
Write-Info "Created content version: $contentVersionId"

# --- 3) Create file record ---
Write-Host "Extracting detection.xml and decoding payload..."
$decodedInfo = Get-EncryptedData -appName $AppName -CommitSuccess $false
$unencryptedLen = [int64]$decodedInfo.UnencryptedFileSize
$innerFileName = $decodedInfo.FileName
$innerFileSize = [int64]$decodedInfo.IntuneWinPackageSize

Write-Host "`n $($unencryptedLen) `n $($innerFileName) `n $($innerFileSize)"

$fileBody = [ordered]@{
    '@odata.type' = '#microsoft.graph.mobileAppContentFile'
    name          = $innerFileName                              # e.g. MyApp.intunewin
    size          = $unencryptedLen                             #[int64]$fileSize  from detection.xml
    sizeEncrypted = $innerFileSize                              # 1204048  .intunewin size
    manifest      = $null
    isDependency  = $false
}

$fileObj = Invoke-RestMethod -Method POST `
  -Uri "https://graph.microsoft.com/v1.0/deviceAppManagement/mobileApps/$appId/microsoft.graph.win32LobApp/contentVersions/$contentVersionId/files" `
  -Headers $Headersgraph `
  -Body ($fileBody | ConvertTo-Json) `
  -ContentType "application/json"
$fileId = $fileObj.id                # GUID (used later for commit)
$sasUrl = $fileObj.azureStorageUri
Write-Info "SAS expires at (UTC): $fileId, ${sasUrl}"


$sasExpiry = $null
if ($fileObj.azureStorageUriExpirationDateTime) {
    $sasExpiry = [datetime]::Parse($fileObj.azureStorageUriExpirationDateTime).ToUniversalTime()
    Write-Info ("SAS expires at (UTC): {0}" -f $sasExpiry.ToString("u"))
}
else {
    Write-Warning "File object did not contain azureStorageUriExpirationDateTime; skipping renew check."
}

Write-Info "File created: $fileId | SAS URL obtained."


# -------------------------
# MAIN
# -------------------------
# 1) Read current file (SAS)

$fileObj = Get-GraphMobileAppContentFile -AppId $AppId -VerId $ContentVersionId -FileId $FileId -Headers $Headersgraph

$timeoutSec = 300
$deadline = (Get-Date).AddSeconds($timeoutSec)

$sas = $null
$uploadReady = $false

do {
    # Refresh metadata
    $fileObj = Get-GraphMobileAppContentFile -AppId $AppId -VerId $ContentVersionId -FileId $FileId -Headers $Headersgraph

    Write-Info "uploadState: $($fileObj.uploadState)"

    # Check readiness
    if ($fileObj.uploadState -eq "azureStorageUriRequestSuccess" -and
        $fileObj.azureStorageUri) {

        $sas = $fileObj.azureStorageUri
        $uploadReady = $true
        break
    }

    Start-Sleep -Seconds 6

} while ((Get-Date) -lt $deadline)

if (-not $uploadReady) {
    throw "SAS URL was not ready before timeout. Final state = $($fileObj.uploadState), SAS = $($fileObj.azureStorageUri)"
}

Write-Info "SAS URL obtained and ready."

# 2) Upload file in blocks and commit blob
$ChunkSizeMB = 4
$innerFilePath = $decodedInfo.IntuneWinFilePath
$blockIds = Send-BlobInBlocks -SasUrl $sas -FilePath $innerFilePath -ChunkSizeMB $ChunkSizeMB

# 3) Commit in Graph with fileEncryptionInfo (using the extracted values)
if (-not $AppId) { Write-Host "AppId is NULL" }
if (-not $ContentVersionId) { Write-Host "ContentVersionId is NULL" }
if (-not $FileId) { Write-Host "FileId is NULL" }

Invoke-GraphCommit -AppId $AppId -VerId $ContentVersionId -FileId $FileId -Headers $Headers  -Data $decodedInfo

# 4) Wait for final commit result
$timeoutSec2 = 600
$deadline2 = (Get-Date).AddSeconds($timeoutSec2)

do {
    Start-Sleep -Seconds 6
    $f2 = Get-GraphMobileAppContentFile -AppId $AppId -VerId $ContentVersionId -FileId $FileId -Headers $Headersgraph
    #Write-Info "uploadState (post-commit): $($f2.uploadState)"
    Write-Host "=== FILE STATUS (POST-COMMIT): ==="
    Write-Host "uploadState: $($f2.uploadState)"
    Write-Host "isCommitted: $($f2.isCommitted)"
    Write-Host "azureStorageUri: $($f2.azureStorageUri)"
    if ($f2.validationInfo) {
        Write-Host "VALIDATION ERRORS:"
        $file.validationInfo | ConvertTo-Json -Depth 5
    }
} while (
    $f2.uploadState -ne "commitFileFailed" -and
    $f2.uploadState -ne "commitFileSuccess" -and
    (Get-Date) -lt $deadline2
)



if ($f2.uploadState -eq "commitFileSuccess") {
    Write-Host "Final uploadState: $($f2.uploadState)"
    Write-Host "Updating CommitedContentVersion.........."
    $body = @{
        "@odata.type"             = "#microsoft.graph.win32LobApp"
        "committedContentVersion" = $contentVersionId
    } | ConvertTo-Json

    # PATCH the app
    
    $uri = "https://graph.microsoft.com/v1.0/deviceAppManagement/mobileApps/$appId"
    Invoke-RestMethod -Method Patch -Uri $uri -Headers $headers -Body $body
}
else {

    Write-Host "Win32 content upload committed successfully."
}



#Check the content versions

$cvUri = "https://graph.microsoft.com/v1.0/deviceAppManagement/mobileApps/$AppId/microsoft.graph.win32LobApp/contentVersions"
$versions = Invoke-RestMethod -Uri $cvUri -Headers $Headers -Method GET
$verId = ($versions.value | Sort-Object id -Descending | Select-Object -First 1).id

# 2. Poll the file upload state
$fileUri = "$cvUri/$verId/files"
$deadline = (Get-Date).AddMinutes(2)
do {
    $files = Invoke-RestMethod -Uri $fileUri -Headers $Headers -Method GET
    $state = $files.value[0].uploadState
    Write-Host "uploadState=$state isCommitted=$($files.value[0].isCommitted)"
    Start-Sleep -Seconds 5
} while ($state -ne "commitFileSuccess" -and (Get-Date) -lt $deadline)


# ---- 3) Poll the app publishing state and committed content version ----
$deadlineApp = (Get-Date).AddMinutes($AppPollTimeoutMinutes)
$finalApp = $null

do {
    $app = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/deviceAppManagement/mobileApps/$AppId" -Headers $Headers -Method GET
    Write-Host "App state: publishingState=$($app.publishingState) committedContentVersion=$($app.committedContentVersion)"
    
    # If committedContentVersion populated, we consider it done.
    if ($app.committedContentVersion) {
        $finalApp = $app
        Write-Host $finalApp
    }

    # Optional: short-circuit if we already see 'published' and file is committed
    if ($app.publishingState -eq "published") {
        # Some tenants briefly show published before committedContentVersion updates; grab again once
        Start-Sleep -Seconds 2
        $app2 = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/deviceAppManagement/mobileApps/$AppId" -Headers $Headers -Method GET
        if ($app2.committedContentVersion) {
            $finalApp = $app2
            break
        }
    }

    Start-Sleep -Seconds 5
} while ((Get-Date) -lt $deadlineApp)

Get-EncryptedData -appName $AppName -CommitSuccess $true
#------------------Apply Dependency--------------------#

if ($DependentAppId) {
    try {

        
        Add-IntuneWin32AppDependency `
                -AccessToken $GraphToken `
                -MainAppId $appId `
                -DependentAppId $DependentAppId `
                -DependencyType "autoInstall"

        Write-Host "Application dependency assigned successfully."
    }
    catch {
        Write-Host "Failed to assign dependency, but continuing script..."
        $exception = $_.Exception

    # 2. Check if the exception contains a Web Response (HTTP Error)
    if ($exception.Response) {
        # Extract the hidden JSON error message sent by Microsoft Graph
        $responseStream = $exception.Response.GetResponseStream()
        $streamReader = [System.IO.StreamReader]::new($responseStream)
        $rawErrorJson = $streamReader.ReadToEnd()
        
        # Convert the JSON to a PowerShell object so we can read it easily
        $errorObj = $rawErrorJson | ConvertFrom-Json

        # Print the detailed Graph API error message
        Write-Host "GRAPH API ERROR:" 
        Write-Host "Code: $($errorObj.error.code)"
        Write-Host "Message: $($errorObj.error.message)"
    }
}   
}
else {
        Write-Host "No dependency provided. Continuing..."
    }
#--------------------Assign UAT Group------------------------#
$GroupName = "UAT-AutoDeployed-Application-Reviewers"
$Intent    = "available"   # available | required | uninstall | availableWithoutEnrollment

# 1) Resolve Group ID
$encodedFilter = [uri]::EscapeDataString("displayName eq '$GroupName'")
$fetchGroupURI = "https://graph.microsoft.com/v1.0/groups?$filter=$encodedFilter"

$headers = @{ Authorization = "Bearer $GraphToken" }

$res = Invoke-RestMethod -Method GET -Uri $fetchGroupURI -Headers $headers

if (-not $res.value -or $res.value.Count -eq 0) {
    throw "Group not found: $GroupName"
}

$GroupId = $res.value[0].id

Write-Host "Assigning app to group $GroupId with intent: $Intent"

# 2) Build assignment body (ARRAY required)
$assignBody = @{
    mobileAppAssignments = @(
        @{
            "@odata.type" = "#microsoft.graph.mobileAppAssignment"
            intent        = $Intent
            target        = @{
                "@odata.type" = "microsoft.graph.groupAssignmentTarget"
                groupId       = $GroupId
            }
        }
    )
}

# 3) Correct Assignment Endpoint
$assignUri = "https://graph.microsoft.com/v1.0/deviceAppManagement/mobileApps/$appId/assign"

Invoke-RestMethod -Method POST -Uri $assignUri -Headers $headers `
    -Body ($assignBody | ConvertTo-Json -Depth 10) `
    -ContentType 'application/json'
