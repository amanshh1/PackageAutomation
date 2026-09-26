[CmdletBinding()]
param(
[Parameter(Mandatory)]
[string]$appName    = "MyApp",
[string]$appID
)
<#
    $SourceFolder      = "C:\NewRunner\actions-runner\_work\Test-Action\UniversalPackageDeployer"
    $SetupFile         = "ServiceUI.exe"
    $BaseOutputRoot     = "C:\NewRunner\actions-runner\_work\Test-Action\IntuneDeploymentPackage"
    $IntuneWinToolPath = "C:\NewRunner\actions-runner\_work\Test-Action\IntuneDeploymentPackage\IntuneWinAppUtil.exe"
#>
$SourceFolder      = Join-Path $env:GITHUB_WORKSPACE "automation-seed\baseline-scripts\UniversalPackageDeployer"
$SetupFile         = "ServiceUI.exe"
$BaseOutputRoot    = Join-Path $env:GITHUB_WORKSPACE "automation-seed\baseline-scripts\IntuneDeploymentPackage"
$IntuneWinToolPath = Join-Path $env:GITHUB_WORKSPACE "automation-seed\baseline-scripts\ContentPrepTool1.8.7\IntuneWinAppUtil.exe"
# Build unique output folder per app/version
$OutputFolder = Join-Path $BaseOutputRoot "$appName"

# Ensure output folder exists
if (-not (Test-Path $OutputFolder)) {
    New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
}
$arguments = @(
    "-c", $SourceFolder
    "-s", $SetupFile
    "-o", $OutputFolder
    "-q"             # Quiet; no interactive catalog question
)

Start-Process -FilePath $IntuneWinToolPath -ArgumentList $arguments -Wait -NoNewWindow

Rename-Item "${OutputFolder}\ServiceUI.intunewin" "${appName}.intunewin"

