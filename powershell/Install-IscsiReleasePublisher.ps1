[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ApiBaseUrl,
    [Parameter(Mandatory = $true)][string]$AdminToken,
    [Parameter(Mandatory = $true)][string]$CaCertificatePath,
    [Parameter(Mandatory = $true)][string]$ClientCertificatePfxPath,
    [Parameter(Mandatory = $true)][SecureString]$ClientCertificatePassword,
    [string]$InstallDirectory = "C:\ProgramData\IscsiResetPublisher",
    [string]$PublisherScriptPath = "$PSScriptRoot\Publish-IscsiRelease.ps1"
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run this installer from an elevated Windows PowerShell 5.1 session"
}
if (-not $ApiBaseUrl.StartsWith("https://")) {
    throw "The release administration API must use HTTPS"
}
foreach ($path in @($CaCertificatePath, $ClientCertificatePfxPath, $PublisherScriptPath)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Required file not found: $path" }
}

New-Item -ItemType Directory -Path $InstallDirectory -Force | Out-Null
$null = Import-Certificate `
    -FilePath $CaCertificatePath `
    -CertStoreLocation "Cert:\LocalMachine\Root"
$clientCertificate = Import-PfxCertificate `
    -FilePath $ClientCertificatePfxPath `
    -CertStoreLocation "Cert:\LocalMachine\My" `
    -Password $ClientCertificatePassword `
    -Exportable:$false
if ($null -eq $clientCertificate -or [string]::IsNullOrWhiteSpace($clientCertificate.Thumbprint)) {
    throw "Client certificate import did not return a thumbprint"
}

$tokenPath = Join-Path $InstallDirectory "admin.token"
$configPath = Join-Path $InstallDirectory "publisher.json"
$installedScript = Join-Path $InstallDirectory "Publish-IscsiRelease.ps1"
Set-Content -LiteralPath $tokenPath -Value $AdminToken.Trim() -NoNewline -Encoding ASCII
[ordered]@{
    api_base_url = $ApiBaseUrl.TrimEnd("/")
    certificate_thumbprint = [string]$clientCertificate.Thumbprint
} | ConvertTo-Json | Set-Content -LiteralPath $configPath -Encoding UTF8
Copy-Item -LiteralPath $PublisherScriptPath -Destination $installedScript -Force

& icacls.exe $InstallDirectory /inheritance:r | Out-Null
& icacls.exe $InstallDirectory `
    /grant:r "SYSTEM:(OI)(CI)F" "Administrators:(OI)(CI)F" | Out-Null
foreach ($path in @($tokenPath, $configPath, $installedScript)) {
    & icacls.exe $path /inheritance:r | Out-Null
    & icacls.exe $path /grant:r "SYSTEM:F" "Administrators:F" | Out-Null
}

Write-Host "Publisher installed: $installedScript"
Write-Host "Client certificate: $($clientCertificate.Thumbprint)"
