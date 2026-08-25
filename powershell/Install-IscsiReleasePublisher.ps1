[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ManifestSourcePath,
    [string]$InstallDirectory = "C:\ProgramData\IscsiResetPublisher",
    [string]$PublisherScriptPath = "",
    [ValidateSet("Enabled", "Disabled", "Aggressive")]
    [string]$EpicGamesManifestSync = "Disabled",
    [ValidateSet("Enabled", "Disabled")]
    [string]$MajesticLauncherSettingsSync = "Disabled"
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($PublisherScriptPath)) {
    $PublisherScriptPath = Join-Path $PSScriptRoot "Publish-IscsiRelease.ps1"
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run this installer from an elevated Windows PowerShell 5.1 session"
}

function Get-MajesticSyncUserProfile {
    param(
        [AllowEmptyString()][string]$Sid = "",
        [AllowEmptyString()][string]$ProfilePath = ""
    )

    if ([string]::IsNullOrWhiteSpace($Sid)) {
        $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
        if ($null -eq $currentIdentity.User) {
            throw "The installer user has no Windows SID"
        }
        $Sid = $currentIdentity.User.Value
    }
    if ($Sid -eq "S-1-5-18") {
        throw "Majestic Launcher settings require an interactive Windows user, not SYSTEM"
    }
    if ([string]::IsNullOrWhiteSpace($ProfilePath)) {
        $ProfilePath = [Environment]::GetFolderPath(
            [Environment+SpecialFolder]::UserProfile
        )
    }
    if ([string]::IsNullOrWhiteSpace($ProfilePath) -or
        -not [IO.Path]::IsPathRooted($ProfilePath) -or
        -not (Test-Path -LiteralPath $ProfilePath -PathType Container) -or
        -not (Test-Path -LiteralPath (Join-Path $ProfilePath "NTUSER.DAT") -PathType Leaf)) {
        throw "The installer user profile and NTUSER.DAT must already exist"
    }
    $profile = Get-Item -LiteralPath $ProfilePath -Force
    if (([int]$profile.Attributes -band [int][IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "The installer user profile must not be a reparse point"
    }
    return [pscustomobject]@{
        Sid = $Sid
        ProfilePath = $profile.FullName
    }
}
foreach ($path in @($ManifestSourcePath, $PublisherScriptPath)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Required file not found: $path" }
}

$manifest = Get-Content -LiteralPath $ManifestSourcePath -Raw | ConvertFrom-Json
if ([int]$manifest.schema_version -ne 1 -or
    [string]::IsNullOrWhiteSpace([string]$manifest.config_revision) -or
    [string]::IsNullOrWhiteSpace([string]$manifest.target_iqn) -or
    @($manifest.volumes).Count -eq 0) {
    throw "Publisher manifest is invalid"
}

New-Item -ItemType Directory -Path $InstallDirectory -Force | Out-Null
$configPath = Join-Path $InstallDirectory "publisher.json"
$installedScript = Join-Path $InstallDirectory "Publish-IscsiRelease.ps1"
$egsConfigPath = Join-Path $InstallDirectory "egs-sync.json"
$majesticConfigPath = Join-Path $InstallDirectory "majestic-sync.json"
Copy-Item -LiteralPath $ManifestSourcePath -Destination $configPath -Force
Copy-Item -LiteralPath $PublisherScriptPath -Destination $installedScript -Force
[ordered]@{
    schema_version = 2
    mode = $EpicGamesManifestSync.ToLowerInvariant()
} | ConvertTo-Json | Set-Content -LiteralPath $egsConfigPath -Encoding UTF8
$majesticProfile = Get-MajesticSyncUserProfile
[ordered]@{
    schema_version = 1
    mode = $MajesticLauncherSettingsSync.ToLowerInvariant()
    user_sid = $majesticProfile.Sid
    profile_path = $majesticProfile.ProfilePath
} | ConvertTo-Json | Set-Content -LiteralPath $majesticConfigPath -Encoding UTF8

& icacls.exe $InstallDirectory /inheritance:r | Out-Null
& icacls.exe $InstallDirectory `
    /grant:r "*S-1-5-18:(OI)(CI)F" "*S-1-5-32-544:(OI)(CI)F" | Out-Null
foreach ($path in @($configPath, $installedScript, $egsConfigPath, $majesticConfigPath)) {
    & icacls.exe $path /inheritance:r | Out-Null
    & icacls.exe $path /grant:r "*S-1-5-18:F" "*S-1-5-32-544:F" | Out-Null
}

Write-Host "Publisher helper installed: $installedScript"
Write-Host "Manifest revision: $($manifest.config_revision)"
Write-Host "Epic Games manifest sync: $EpicGamesManifestSync."
Write-Host "Majestic Launcher settings sync: $MajesticLauncherSettingsSync."
Write-Host "Use -Action Disconnect before staging and -Action Reconnect after activation."
