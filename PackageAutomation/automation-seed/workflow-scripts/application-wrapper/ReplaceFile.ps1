# Define source and destination paths
$sourceFile = Join-Path $env:GITHUB_WORKSPACE "automation-seed/baseline-scripts/DeploymentScriptFile/Deploy-Application.ps1"

$destinationFile = Join-Path $env:GITHUB_WORKSPACE "automation-seed/baseline-scripts/UniversalPackageDeployer/Deploy-Application.ps1"

# Check if the destination file exists
if (Test-Path $destinationFile) {
    # Remove the existing file
    Remove-Item $destinationFile -Force
    Write-Host "Existing file removed."
}

# Copy the new file to the destination
Copy-Item $sourceFile -Destination $destinationFile
Write-Host "New file copied successfully."