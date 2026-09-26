[CmdletBinding()]
Param (
    [Parameter(Mandatory = $false)]
    [ValidateSet('Install', 'Uninstall')]
    [string]$DeploymentType = 'Install',
    [Parameter(Mandatory = $false)]
    [ValidateSet('Interactive', 'Silent', 'NonInteractive')]
    [string]$DeployMode = 'Interactive',
    [Parameter(Mandatory = $false)]
    [switch]$AllowRebootPassThru = $false,
    [Parameter(Mandatory = $false)]
    [switch]$TerminalServerMode = $false,
    [Parameter(Mandatory = $false)]
    [switch]$DisableLogging = $false
)

Try {
    ## Set the script execution policy for this process
    Try { Set-ExecutionPolicy -ExecutionPolicy 'ByPass' -Scope 'Process' -Force -ErrorAction 'Stop' } Catch {}
	
    ##*===============================================
    ##* VARIABLE DECLARATION
    ##*===============================================
    ## Variables: Application
    [String]$appVendor = 'Igor Pavlov'
    [String]$appName = '7-Zip'
    [String]$appVersion = '25.01'
    [String]$appArch = 'x64'
    [String]$appLang = 'EN'
    [String]$appRevision = '02'
    [String]$appScriptVersion = '2.0.0'
    [String]$appScriptDate = '30/12/2025'
    [string]$appScriptAuthor = 'AppLife-Cycle-Deployment Team'
    ##*===============================================
	
    ##* Do not modify section below
    #region DoNotModify
	
    ## Variables: Exit Code
    [int32]$mainExitCode = 0
	
    ## Variables: Script
    [string]$deployAppScriptFriendlyName = 'Deploy Application'
    [version]$deployAppScriptVersion = [version]'3.6.5'
    [string]$deployAppScriptDate = '08/17/2015'
    [hashtable]$deployAppScriptParameters = $psBoundParameters
	
    ## Variables: Environment
    If (Test-Path -LiteralPath 'variable:HostInvocation') { $InvocationInfo = $HostInvocation } Else { $InvocationInfo = $MyInvocation }
    [string]$scriptDirectory = Split-Path -Path $InvocationInfo.MyCommand.Definition -Parent
	
    ## Dot source the required App Deploy Toolkit Functions
    Try {
        [string]$moduleAppDeployToolkitMain = "$scriptDirectory\AppDeployToolkit\AppDeployToolkitMain.ps1"
        If (-not (Test-Path -LiteralPath $moduleAppDeployToolkitMain -PathType 'Leaf')) { Throw "Module does not exist at the specified location [$moduleAppDeployToolkitMain]." }
        If ($DisableLogging) { . $moduleAppDeployToolkitMain -DisableLogging } Else { . $moduleAppDeployToolkitMain }
    }
    Catch {
        If ($mainExitCode -eq 0) { [int32]$mainExitCode = 60008 }
        Write-Error -Message "Module [$moduleAppDeployToolkitMain] failed to load: `n$($_.Exception.Message)`n `n$($_.InvocationInfo.PositionMessage)" -ErrorAction 'Continue'
        ## Exit the script, returning the exit code to SCCM
        If (Test-Path -LiteralPath 'variable:HostInvocation') { $script:ExitCode = $mainExitCode; Exit } Else { Exit $mainExitCode }
    }
	
    #endregion
    ##* Do not modify section above
    ##*===============================================
    ##* END VARIABLE DECLARATION
    ##*===============================================
	
    If ($deploymentType -ine 'Uninstall') {
        ##*===============================================
        ##* PRE-INSTALLATION
        ##*===============================================
        [string]$installPhase = 'Pre-Installation'
		
        #Show-InstallationProgress
	    
        ##*===============================================
        ##* INSTALLATION
        ##*===============================================
        [string]$installPhase = 'Installation'
		
		
        

       
        # Install Google Chrome

        # ================= CONFIG: Update these per app =================
        $AppName = '7-Zip'
        $WingetId = '7zip.7zip'
        $LogRoot = 'C:\Windows\Maersk\WingetLogs'
        $LogFileName = "${AppName}_Fresh_Installation.log"
        $RegistryPath = "HKLM:\SOFTWARE\WOW6432Node\ManageSoft Corp\ManageSoft\Usage Agent\CurrentVersion\Manual Mapper\Win_${AppName.Replace(' ','_')}_R1"
        $ExecutableRegex = ".*\\" + "${AppName}.exe"
        $BalloonTitle = "$AppName Notification"
        # ================================================================

        # Create log directory and file
        New-Item -Path $LogRoot -ItemType Directory -Force | Out-Null
        $log = Join-Path $LogRoot $LogFileName
        $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        Set-Content -Path $log -Value "Script started at $timestamp"

        # Resolve Winget path
        $WingetPath = (Resolve-Path "C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\winget.exe")[-1].Path
        $Winget = Get-ChildItem $WingetPath -File | Where-Object { $_.Name -like "Winget.exe" } | Select-Object -ExpandProperty FullName

        # Balloon Notification Function
        function Show-BalloonNotification {
            param (
                [string]$Title = $BalloonTitle,
                [string]$Message,
                [int]$Duration = 5000
            )
            Add-Type -AssemblyName System.Windows.Forms
            Add-Type -AssemblyName System.Drawing
            $notifyIcon = New-Object System.Windows.Forms.NotifyIcon
            $notifyIcon.Icon = [System.Drawing.SystemIcons]::Information
            $notifyIcon.BalloonTipTitle = $Title
            $notifyIcon.BalloonTipText = $Message
            $notifyIcon.Visible = $true
            $notifyIcon.ShowBalloonTip($Duration)
            Start-Sleep -Milliseconds ($Duration + 1000)
            $notifyIcon.Dispose()
        }

        # Install Function
        function Install-App {
            $cmdline = "`"$Winget`" install --id $WingetId --source winget --accept-package-agreements --accept-source-agreements -h"
            $WingetInstall = cmd /c $cmdline | Out-String
            Start-Sleep -Seconds 15
            $WingetInstall | Out-File -FilePath $log -Append -Encoding utf8
            Start-Sleep -Seconds 15

            if ($WingetInstall -match "Successfully installed") {
                New-Item -Path $RegistryPath -Force | Out-Null
                New-ItemProperty -Path $RegistryPath -Name 'Application' -Value $AppName -PropertyType 'String' -Force
                New-ItemProperty -Path $RegistryPath -Name 'Regex' -Value 'True' -PropertyType 'String' -Force
                New-ItemProperty -Path $RegistryPath -Name 'Version' -Value '' -PropertyType 'String' -Force
                New-ItemProperty -Path $RegistryPath -Name 'ExecutablePath' -Value $ExecutableRegex -PropertyType 'String' -Force
                

                Show-BalloonNotification -Message "$AppName Successfully installed to latest version."
                Add-Content -Path $log -Value "$($timestamp) - $AppName Successfully installed."
            }
            elseif ($WingetInstall -match "No package found matching input criteria") {
                Add-Content -Path $log -Value "$($timestamp) - $AppName No package found. Retrying..."
                Install-App
            }
            else {
                Add-Content -Path $log -Value "$($timestamp) - $AppName installation failed. Retrying..."
                Install-App
            }
        }

        # Main Execution
        Install-App





        ##*===============================================
        ##* POST-INSTALLATION
        ##*===============================================
        [string]$installPhase = 'Post-Installation'
		#\{Apply-Registry-Section\}
    }
    ElseIf ($deploymentType -ieq 'Uninstall') {
        ##*===============================================
        ##* PRE-UNINSTALLATION
        ##*===============================================
        [string]$installPhase = 'Pre-Uninstallation'
		
        ## Prompt the user to close the following applications if they are running:
        ##Show-InstallationWelcome -CloseApps 'iexplore,AcroRd32,cidaemon' -AllowDefer -DeferTimes 3
		
        ## Show Progress Message (with a message to indicate the application is being uninstalled)
        # Show-InstallationProgress -StatusMessage 'Uninstalling application [$installTitle]. Please Wait...'
		
		
        ##*===============================================
        ##* UNINSTALLATION
        ##*===============================================

        
        
        [string]$installPhase = 'Uninstallation'


        $registryPath = "HKLM:\SOFTWARE\WOW6432Node\ManageSoft Corp\ManageSoft\Usage Agent\CurrentVersion\Manual Mapper\Win_Google_Chrome_Fresh_Installation_R1"

        if (Test-Path -Path $registryPath) {
            Remove-Item -Path $registryPath -Recurse -force | Out-Null
        }


        function Uninstall-App {
            Add-Content -Path $log -Value "$($timestamp) - Starting uninstall for $AppName"

            # Registry paths to check
            $regPaths = @(
                'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
                'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
            )

            $uninstallCmd = $null
            foreach ($path in $regPaths) {
                $apps = Get-ChildItem -Path $path | ForEach-Object {
                    Get-ItemProperty $_.PSPath
                }
                $match = $apps | Where-Object { $_.DisplayName -eq $AppName }
                if ($match) {
                    $uninstallCmd = $match.QuietUninstallString
                    if (-not $uninstallCmd) { $uninstallCmd = $match.UninstallString }
                    break
                }
            }

            if (-not $uninstallCmd) {
                Add-Content -Path $log -Value "$($timestamp) - $AppName not found in registry."
                Show-BalloonNotification -Message "$AppName is not installed."
                return
            }

            Add-Content -Path $log -Value "$($timestamp) - Uninstall command: $uninstallCmd"

            # Execute silently
            try {
                $process = Start-Process -FilePath "cmd.exe" -ArgumentList "/c $uninstallCmd /quiet /norestart" -Wait -PassThru
                if ($process.ExitCode -eq 0) {
                    # Remove custom registry entries
                    if (Test-Path $RegistryPath) {
                        Remove-Item -Path $RegistryPath -Recurse -Force
                        Add-Content -Path $log -Value "$($timestamp) - Removed registry path: $RegistryPath"
                    }
                    Show-BalloonNotification -Message "$AppName successfully uninstalled."
                    Add-Content -Path $log -Value "$($timestamp) - $AppName uninstall completed."
                }
                else {
                    Add-Content -Path $log -Value "$($timestamp) - Uninstall failed with exit code $($process.ExitCode)"
                    Show-BalloonNotification -Message "$AppName uninstall failed."
                }
            }
            catch {
                Add-Content -Path $log -Value "$($timestamp) - Error during uninstall: $_"
                Show-BalloonNotification -Message "$AppName uninstall encountered an error."
            }
        }

        Uninstall-App
        ##*===============================================
        ##* POST-UNINSTALLATION
        ##*===============================================
        [string]$installPhase = 'Post-Uninstallation'
		
        ## <Perform Post-Uninstallation tasks here>
        
        function Post-UninstallCleanup {
            param(
                [string]$AppName,
                [string]$VendorFolderName,
                [string]$RegistryPath,
                [string[]]$ExtraPathsToDelete
            )

            Add-Content -Path $log -Value "$($timestamp) - Starting post-uninstall cleanup for $AppName"

            # 1) Remove custom detection/usage key created during install
            try {
                if (Test-Path -LiteralPath $RegistryPath) {
                    Remove-Item -Path $RegistryPath -Recurse -Force -ErrorAction Stop
                    Add-Content -Path $log -Value "$($timestamp) - Removed custom registry path: $RegistryPath"
                }
                else {
                    Add-Content -Path $log -Value "$($timestamp) - Custom registry path not found: $RegistryPath"
                }
            }
            catch {
                Add-Content -Path $log -Value "$($timestamp) - Failed to remove registry path ($RegistryPath): $($_.Exception.Message)"
            }

            # 2) Remove common residual folders (Program Files / ProgramData)
            $pathsToDelete = @(
                "$env:ProgramFiles\$VendorFolderName\$AppName",
                "$env:ProgramFiles\$AppName",
                "$env:ProgramFiles (x86)\$VendorFolderName\$AppName",
                "$env:ProgramFiles (x86)\$AppName",
                "C:\ProgramData\$VendorFolderName\$AppName",
                "C:\ProgramData\$AppName"
            ) + $ExtraPathsToDelete

            foreach ($p in $pathsToDelete | Where-Object { $_ -and $_.Trim() -ne '' }) {
                try {
                    if (Test-Path -LiteralPath $p) {
                        # Remove ReadOnly attributes to avoid failures
                        Get-ChildItem -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
                            $_.Attributes = 'Normal'
                        }
                        Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction Stop
                        Add-Content -Path $log -Value "$($timestamp) - Deleted folder: $p"
                    }
                    else {
                        Add-Content -Path $log -Value "$($timestamp) - Folder not found (skip): $p"
                    }
                }
                catch {
                    Add-Content -Path $log -Value "$($timestamp) - Failed deleting $p: $($_.Exception.Message)"
                }
            }

            # 3) Clean per-user AppData (Local & Roaming)
            try {
                $userRoots = Get-ChildItem -Path 'C:\Users' -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notin @('Public', 'Default', 'Default User', 'All Users') }

                foreach ($u in $userRoots) {
                    $localPaths = @(
                        Join-Path $u.FullName "AppData\Local\$VendorFolderName\$AppName",
                        Join-Path $u.FullName "AppData\Local\$AppName"
                    )
                    $roamingPaths = @(
                        Join-Path $u.FullName "AppData\Roaming\$VendorFolderName\$AppName",
                        Join-Path $u.FullName "AppData\Roaming\$AppName"
                    )

                    foreach ($p in $localPaths + $roamingPaths) {
                        try {
                            if (Test-Path -LiteralPath $p) {
                                Get-ChildItem -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
                                    $_.Attributes = 'Normal'
                                }
                                Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction Stop
                                Add-Content -Path $log -Value "$($timestamp) - Deleted per-user folder: $p"
                            }
                        }
                        catch {
                            Add-Content -Path $log -Value "$($timestamp) - Failed deleting per-user folder $p: $($_.Exception.Message)"
                        }
                    }

                    # 4) Clear per-user TEMP entries referencing the app name
                    $userTemp = Join-Path $u.FullName 'AppData\Local\Temp'
                    if (Test-Path -LiteralPath $userTemp) {
                        try {
                            Get-ChildItem -LiteralPath $userTemp -Recurse -Force -ErrorAction SilentlyContinue |
                            Where-Object { $_.Name -like "*$AppName*" -or $_.FullName -like "*$VendorFolderName*" } |
                            ForEach-Object {
                                try {
                                    Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop
                                    Add-Content -Path $log -Value "$($timestamp) - Deleted temp item: $($_.FullName)"
                                }
                                catch {
                                    # Skip locked files
                                }
                            }
                        }
                        catch {
                            Add-Content -Path $log -Value "$($timestamp) - Temp cleanup failed for $($u.FullName): $($_.Exception.Message)"
                        }
                    }
                }
            }
            catch {
                Add-Content -Path $log -Value "$($timestamp) - Enumerating user profiles failed: $($_.Exception.Message)"
            }

            # 5) Clear system TEMP entries referencing the app
            try {
                Get-ChildItem -Path $env:TEMP -Recurse -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like "*$AppName*" -or $_.FullName -like "*$VendorFolderName*" } |
                ForEach-Object {
                    try {
                        Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop
                    }
                    catch { }
                }
                Add-Content -Path $log -Value "$($timestamp) - Cleared system TEMP entries for $AppName"
            }
            catch {
                Add-Content -Path $log -Value "$($timestamp) - System TEMP cleanup failed: $($_.Exception.Message)"
            }

            Add-Content -Path $log -Value "$($timestamp) - Post-uninstall cleanup complete for $AppName"
        }

    }
	
    Post-UninstallCleanup

    ##*===============================================
    ##* END SCRIPT BODY
    ##*===============================================
	
    ## Call the Exit-Script function to perform final cleanup operations
    Exit-Script -ExitCode $mainExitCode
}
Catch {
    [int32]$mainExitCode = 1
    [string]$mainErrorMessage = "$(Resolve-Error)"
    Write-Log -Message $mainErrorMessage -Severity 3 -Source $deployAppScriptFriendlyName
    Show-DialogBox -Text $mainErrorMessage -Icon 'Stop'
    Exit-Script -ExitCode $mainExitCode
}
