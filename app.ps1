#requires -version 5.1
<#
    Install or upgrade common applications silently via winget.
    Run PowerShell as Administrator.

    Behavior:
    - If the application is not installed: install it.
    - If the application is installed and an upgrade is available: upgrade it.
    - If the application is already up to date: skip it.
    - Show only simple progress and final summary.
    - Save detailed winget output to a log file.

    Remote execution:
    irm https://raw.githubusercontent.com/phucanmis/mrant/main/apps-install.ps1 | iex
#>

$ErrorActionPreference = "Continue"

# Change this value if you want to use another winget source.
$WingetSource = "winget"

# Use "machine" for all users. Requires Administrator.
$InstallScope = "machine"

# Log file path
$TimeStamp = Get-Date -Format "yyyyMMdd-HHmmss"

# $PSScriptRoot is empty when running via "irm URL | iex".
# Use TEMP folder as fallback for remote execution.
if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    $ScriptRoot = $PSScriptRoot
}
else {
    $ScriptRoot = Join-Path $env:TEMP "mrant-winget"
}

if (-not (Test-Path $ScriptRoot)) {
    New-Item -Path $ScriptRoot -ItemType Directory -Force | Out-Null
}

$LogPath = Join-Path $ScriptRoot "winget-install-$TimeStamp.log"

# Result buckets
$InstalledApps = New-Object System.Collections.Generic.List[string]
$UpgradedApps = New-Object System.Collections.Generic.List[string]
$SkippedApps = New-Object System.Collections.Generic.List[string]
$FailedApps = New-Object System.Collections.Generic.List[string]
$UnavailableApps = New-Object System.Collections.Generic.List[string]

function Write-Log {
    param(
        [string]$Message
    )

    if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
        Add-Content -Path $LogPath -Value $Message -Encoding UTF8
    }
}

function Invoke-WingetQuiet {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [string]$Title = "winget"
    )

    Write-Log ""
    Write-Log "============================================================"
    Write-Log "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Title"
    Write-Log "Command: winget $($Arguments -join ' ')"
    Write-Log "============================================================"

    $Output = & winget @Arguments 2>&1
    $ExitCode = $LASTEXITCODE

    if ($null -ne $Output) {
        $OutputText = ($Output | Out-String).Trim()
    }
    else {
        $OutputText = ""
    }

    if ($OutputText -ne "") {
        Write-Log $OutputText
    }

    Write-Log "ExitCode: $ExitCode"

    return [PSCustomObject]@{
        ExitCode = $ExitCode
        Output   = $OutputText
    }
}

function Test-IsAdministrator {
    $CurrentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $Principal = New-Object Security.Principal.WindowsPrincipal($CurrentIdentity)
    return $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Resolve-PackageId {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$App
    )

    if ($App.ContainsKey("CandidateIds")) {
        foreach ($CandidateId in $App.CandidateIds) {
            $ShowArgs = @(
                "show",
                "--id", $CandidateId,
                "--exact",
                "--source", $WingetSource,
                "--accept-source-agreements",
                "--disable-interactivity"
            )

            $Result = Invoke-WingetQuiet -Arguments $ShowArgs -Title "Check package availability: $CandidateId"

            if ($Result.ExitCode -eq 0) {
                return $CandidateId
            }
        }

        return $null
    }

    return $App.Id
}

function Install-App {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Id,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [string]$OverrideInstall = ""
    )

    $InstallArgs = @(
        "install",
        "--id", $Id,
        "--exact",
        "--source", $WingetSource,
        "--silent",
        "--accept-package-agreements",
        "--accept-source-agreements",
        "--disable-interactivity",
        "--scope", $InstallScope
    )

    if ($OverrideInstall -ne "") {
        $InstallArgs += @("--override", $OverrideInstall)
    }

    $Result = Invoke-WingetQuiet -Arguments $InstallArgs -Title "Install: $Name [$Id]"

    # Retry without machine scope if machine-scope install fails.
    if ($Result.ExitCode -ne 0) {
        $RetryArgs = @(
            "install",
            "--id", $Id,
            "--exact",
            "--source", $WingetSource,
            "--silent",
            "--accept-package-agreements",
            "--accept-source-agreements",
            "--disable-interactivity"
        )

        if ($OverrideInstall -ne "") {
            $RetryArgs += @("--override", $OverrideInstall)
        }

        $Result = Invoke-WingetQuiet -Arguments $RetryArgs -Title "Install retry without scope: $Name [$Id]"
    }

    return $Result
}

function Upgrade-App {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Id,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $UpgradeArgs = @(
        "upgrade",
        "--id", $Id,
        "--exact",
        "--source", $WingetSource,
        "--silent",
        "--accept-package-agreements",
        "--accept-source-agreements",
        "--disable-interactivity"
    )

    $Result = Invoke-WingetQuiet -Arguments $UpgradeArgs -Title "Upgrade: $Name [$Id]"

    return $Result
}

function Install-OrUpgradeApp {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$App,

        [Parameter(Mandatory = $true)]
        [int]$Index,

        [Parameter(Mandatory = $true)]
        [int]$Total
    )

    $Name = $App.Name

    Write-Progress `
        -Activity "Installing or upgrading applications" `
        -Status "$Index of $Total - $Name" `
        -PercentComplete (($Index / $Total) * 100)

    Write-Host ("[{0}/{1}] {2} ... " -f $Index, $Total, $Name) -NoNewline

    $PackageId = Resolve-PackageId -App $App

    if ([string]::IsNullOrWhiteSpace($PackageId)) {
        Write-Host "Unavailable" -ForegroundColor DarkYellow
        $UnavailableApps.Add($Name)
        return
    }

    $OverrideInstall = ""
    if ($App.ContainsKey("OverrideInstall")) {
        $OverrideInstall = $App.OverrideInstall
    }

    # Try upgrade first.
    # If the application is not installed, winget will report that no installed package was found.
    $UpgradeResult = Upgrade-App -Id $PackageId -Name $Name
    $UpgradeOutput = $UpgradeResult.Output

    $NoInstalledPattern = "(?i)No installed package found|No package found matching input criteria|not installed"
    $NoUpgradePattern = "(?i)No available upgrade found|No newer package versions are available|No applicable update found"
    $AlreadyInstalledPattern = "(?i)already installed|No newer package versions are available|No available upgrade found"

    if ($UpgradeOutput -match $NoInstalledPattern) {
        $InstallResult = Install-App -Id $PackageId -Name $Name -OverrideInstall $OverrideInstall
        $InstallOutput = $InstallResult.Output

        if ($InstallResult.ExitCode -eq 0) {
            if ($InstallOutput -match $AlreadyInstalledPattern) {
                Write-Host "Skipped" -ForegroundColor Gray
                $SkippedApps.Add($Name)
            }
            else {
                Write-Host "Installed" -ForegroundColor Green
                $InstalledApps.Add($Name)
            }
        }
        else {
            Write-Host "Failed" -ForegroundColor Red
            $FailedApps.Add($Name)
        }

        return
    }

    if ($UpgradeOutput -match $NoUpgradePattern) {
        Write-Host "Skipped" -ForegroundColor Gray
        $SkippedApps.Add($Name)
        return
    }

    if ($UpgradeResult.ExitCode -eq 0) {
        Write-Host "Upgraded" -ForegroundColor Cyan
        $UpgradedApps.Add($Name)
        return
    }

    # Fallback: try install if upgrade failed.
    $InstallFallback = Install-App -Id $PackageId -Name $Name -OverrideInstall $OverrideInstall

    if ($InstallFallback.ExitCode -eq 0) {
        if ($InstallFallback.Output -match $AlreadyInstalledPattern) {
            Write-Host "Skipped" -ForegroundColor Gray
            $SkippedApps.Add($Name)
        }
        else {
            Write-Host "Installed" -ForegroundColor Green
            $InstalledApps.Add($Name)
        }
    }
    else {
        Write-Host "Failed" -ForegroundColor Red
        $FailedApps.Add($Name)
    }
}

# Start log
Write-Log "Winget install started at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Log "Source: $WingetSource"
Write-Log "Scope: $InstallScope"

# Check winget
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Host "winget is not installed or not available." -ForegroundColor Red
    Write-Host "Please install or update App Installer from Microsoft Store." -ForegroundColor Yellow
    exit 1
}

# Administrator warning
if (-not (Test-IsAdministrator)) {
    Write-Host "Warning: PowerShell is not running as Administrator. Some machine-scope installs may fail." -ForegroundColor Yellow
}

# Update only the selected winget source quietly.
# This avoids Microsoft Store source certificate issues on some machines.
Invoke-WingetQuiet -Arguments @(
    "source",
    "update",
    "--name", $WingetSource,
    "--disable-interactivity"
) -Title "Update winget source" | Out-Null

# Application list
$Apps = @(
    @{ Name = "WinSCP"; Id = "WinSCP.WinSCP" },
    @{ Name = "PuTTY"; Id = "PuTTY.PuTTY" },
    @{ Name = "Google Chrome"; Id = "Google.Chrome" },
    @{ Name = "Visual Studio Code"; Id = "Microsoft.VisualStudioCode" },
    @{ Name = "Git"; Id = "Git.Git" },
    @{ Name = "Notepad++"; Id = "Notepad++.Notepad++" },
    @{ Name = "RealVNC Viewer"; Id = "RealVNC.VNCViewer" },
    @{ Name = "WireGuard Client"; Id = "WireGuard.WireGuard" },

    # Cisco Client package IDs can vary depending on availability.
    @{ Name = "Cisco Client"; CandidateIds = @("Cisco.CiscoSecureClient", "Cisco.AnyConnect") },

    @{ Name = "WinRAR"; Id = "RARLab.WinRAR" },
    @{ Name = "7-Zip"; Id = "7zip.7zip" },
    @{ Name = "HWMonitor"; Id = "CPUID.HWMonitor" },
    @{ Name = "CrystalDiskInfo"; Id = "CrystalDewWorld.CrystalDiskInfo" },
    @{ Name = "Mozilla Firefox"; Id = "Mozilla.Firefox" },
    @{ Name = "Steam"; Id = "Valve.Steam" },
    @{ Name = "Coc Coc"; Id = "CocCoc.CocCoc" },

    # Visual Studio Community 2022
    # Workloads:
    # - .NET desktop development
    # - Desktop development with C++
    @{
        Name = "Visual Studio 2022 Community"
        Id = "Microsoft.VisualStudio.2022.Community"
        OverrideInstall = "--wait --quiet --norestart --add Microsoft.VisualStudio.Workload.ManagedDesktop --add Microsoft.VisualStudio.Workload.NativeDesktop --includeRecommended"
    }
)

$Total = $Apps.Count
$Index = 0

foreach ($App in $Apps) {
    $Index++
    Install-OrUpgradeApp -App $App -Index $Index -Total $Total
}

Write-Progress -Activity "Installing or upgrading applications" -Completed

# Final summary
Write-Host ""
Write-Host "================ SUMMARY ================" -ForegroundColor White

Write-Host ("Installed   : {0}" -f $InstalledApps.Count) -ForegroundColor Green
foreach ($Item in $InstalledApps) {
    Write-Host "  + $Item" -ForegroundColor Green
}

Write-Host ("Upgraded    : {0}" -f $UpgradedApps.Count) -ForegroundColor Cyan
foreach ($Item in $UpgradedApps) {
    Write-Host "  ^ $Item" -ForegroundColor Cyan
}

Write-Host ("Skipped     : {0}" -f $SkippedApps.Count) -ForegroundColor Gray
foreach ($Item in $SkippedApps) {
    Write-Host "  - $Item" -ForegroundColor Gray
}

Write-Host ("Unavailable : {0}" -f $UnavailableApps.Count) -ForegroundColor DarkYellow
foreach ($Item in $UnavailableApps) {
    Write-Host "  ! $Item" -ForegroundColor DarkYellow
}

Write-Host ("Failed      : {0}" -f $FailedApps.Count) -ForegroundColor Red
foreach ($Item in $FailedApps) {
    Write-Host "  x $Item" -ForegroundColor Red
}

Write-Host "=========================================" -ForegroundColor White
Write-Host "Detailed log: $LogPath" -ForegroundColor Yellow
Write-Host "Done." -ForegroundColor Green
