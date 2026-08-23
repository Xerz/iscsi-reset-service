[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ManifestSourcePath,
    [string]$InstallDirectory = "C:\ProgramData\IscsiResetPublisher",
    [string]$PublisherScriptPath = "",
    [ValidateSet("Enabled", "Disabled", "Aggressive")]
    [string]$EpicGamesManifestSync = "Disabled"
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
Copy-Item -LiteralPath $ManifestSourcePath -Destination $configPath -Force
Copy-Item -LiteralPath $PublisherScriptPath -Destination $installedScript -Force
[ordered]@{
    schema_version = 2
    mode = $EpicGamesManifestSync.ToLowerInvariant()
} | ConvertTo-Json | Set-Content -LiteralPath $egsConfigPath -Encoding UTF8

& icacls.exe $InstallDirectory /inheritance:r | Out-Null
& icacls.exe $InstallDirectory `
    /grant:r "*S-1-5-18:(OI)(CI)F" "*S-1-5-32-544:(OI)(CI)F" | Out-Null
foreach ($path in @($configPath, $installedScript, $egsConfigPath)) {
    & icacls.exe $path /inheritance:r | Out-Null
    & icacls.exe $path /grant:r "*S-1-5-18:F" "*S-1-5-32-544:F" | Out-Null
}

Write-Host "Publisher helper installed: $installedScript"
Write-Host "Manifest revision: $($manifest.config_revision)"
Write-Host "Epic Games manifest sync: $EpicGamesManifestSync."
Write-Host "Use -Action Disconnect before staging and -Action Reconnect after activation."
