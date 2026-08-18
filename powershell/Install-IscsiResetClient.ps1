[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Token,
    [Parameter(Mandatory = $true)][string]$CaCertificatePath,
    [string]$ApiBaseUrl = "https://10.20.40.10:8443",
    [string]$InstallRoot = "C:\ProgramData\IscsiReset",
    [string]$ClientScriptPath = (Join-Path $PSScriptRoot "Reset-And-Connect.ps1")
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run this installer from an elevated Windows PowerShell 5.1 prompt"
}
if (-not $ApiBaseUrl.StartsWith("https://")) { throw "ApiBaseUrl must use HTTPS" }
if (-not (Test-Path -LiteralPath $ClientScriptPath)) { throw "Client script not found" }
if (-not (Test-Path -LiteralPath $CaCertificatePath)) { throw "CA certificate not found" }

New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $InstallRoot "logs") -Force | Out-Null
$installedScript = Join-Path $InstallRoot "Reset-And-Connect.ps1"
$tokenPath = Join-Path $InstallRoot "client.token"
Copy-Item -LiteralPath $ClientScriptPath -Destination $installedScript -Force
[System.IO.File]::WriteAllText($tokenPath, $Token, (New-Object System.Text.UTF8Encoding($false)))

$acl = New-Object System.Security.AccessControl.FileSecurity
$acl.SetAccessRuleProtection($true, $false)
foreach ($account in @("NT AUTHORITY\SYSTEM", "BUILTIN\Administrators")) {
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $account,
        "FullControl",
        "Allow"
    )
    $acl.AddAccessRule($rule)
}
Set-Acl -LiteralPath $tokenPath -AclObject $acl

Import-Certificate -FilePath $CaCertificatePath -CertStoreLocation "Cert:\LocalMachine\Root" | Out-Null
Set-Service -Name MSiSCSI -StartupType Automatic
Start-Service -Name MSiSCSI

$headers = @{ Authorization = "Bearer $Token"; "X-Request-ID" = [Guid]::NewGuid().ToString("D") }
$client = Invoke-RestMethod -Method GET -Uri "$ApiBaseUrl/v1/client" -Headers $headers -TimeoutSec 30
foreach ($session in @(Get-IscsiSession | Where-Object {
    $_.TargetNodeAddress -eq [string]$client.target_iqn -and $_.IsPersistent
})) {
    Unregister-IscsiSession -SessionIdentifier $session.SessionIdentifier
}

$powerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$installedScript`" -ApiBaseUrl `"$ApiBaseUrl`" -TokenPath `"$tokenPath`""
$action = New-ScheduledTaskAction -Execute $powerShell -Argument $arguments
$trigger = New-ScheduledTaskTrigger -AtStartup
$trigger.Delay = "PT15S"
$principalTask = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName "iSCSI Reset and Connect" -Action $action -Trigger $trigger `
    -Principal $principalTask -Settings $settings -Force | Out-Null

Write-Host "Installed iSCSI reset client. Reboot to run the first reset and non-persistent login."

