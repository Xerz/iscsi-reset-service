[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$CaCertificatePath,
    [string]$ResetApiIp,
    [string]$InstallRoot = "C:\ProgramData\IscsiReset",
    [string]$ClientScriptPath = "",
    [ValidateSet("Enabled", "Disabled", "Aggressive")]
    [string]$EpicGamesManifestSync = "Disabled"
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($ClientScriptPath)) {
    $ClientScriptPath = Join-Path $PSScriptRoot "Reset-And-Connect.ps1"
}

function Resolve-ResetApiAddress {
    param([AllowEmptyString()][string]$Address)

    $candidate = $Address
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        $candidate = Read-Host "Reset API IP [10.20.40.10]"
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            $candidate = "10.20.40.10"
        }
    }
    $candidate = $candidate.Trim()

    $parsed = $null
    $isIp = [System.Net.IPAddress]::TryParse($candidate, [ref]$parsed)
    if (-not $isIp -or
        $parsed.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork -or
        $parsed.ToString() -ne $candidate) {
        throw "ResetApiIp must be a canonical IPv4 address"
    }

    return [pscustomobject]@{
        Ip = $candidate
        BaseUrl = "https://${candidate}:8443"
    }
}

function Read-ClientToken {
    $secureToken = Read-Host "Client token" -AsSecureString
    $pointer = [IntPtr]::Zero
    try {
        $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureToken)
        $plainText = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
        if ([string]::IsNullOrWhiteSpace($plainText)) {
            throw "Client token must not be empty"
        }
        return [pscustomobject]@{
            PlainText = $plainText
            SecureString = $secureToken
        }
    }
    catch {
        $secureToken.Dispose()
        throw
    }
    finally {
        if ($pointer -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
        }
    }
}

function New-RestrictedFileSystemAcl {
    param([switch]$Directory)

    if ($Directory) {
        $acl = New-Object System.Security.AccessControl.DirectorySecurity
    }
    else {
        $acl = New-Object System.Security.AccessControl.FileSecurity
    }
    $acl.SetAccessRuleProtection($true, $false)

    foreach ($sidValue in @("S-1-5-18", "S-1-5-32-544")) {
        $sid = New-Object System.Security.Principal.SecurityIdentifier($sidValue)
        if ($Directory) {
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                $sid,
                "FullControl",
                "ContainerInherit, ObjectInherit",
                "None",
                "Allow"
            )
        }
        else {
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                $sid,
                "FullControl",
                "Allow"
            )
        }
        $acl.AddAccessRule($rule)
    }
    return $acl
}

function New-ClientRequestHeaders {
    param([Parameter(Mandatory = $true)][string]$ClientToken)

    return @{
        Authorization = "Bearer $ClientToken"
        "X-Request-ID" = [Guid]::NewGuid().ToString("D")
    }
}

function New-ResetScheduledTaskArguments {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [Parameter(Mandatory = $true)][string]$ClientTokenPath
    )

    return "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass " +
        "-File `"$ScriptPath`" -ApiBaseUrl `"$BaseUrl`" " +
        "-TokenPath `"$ClientTokenPath`""
}

function Invoke-IscsiResetClientInstall {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Run this installer from an elevated Windows PowerShell 5.1 prompt"
    }
    if (-not (Test-Path -LiteralPath $ClientScriptPath)) { throw "Client script not found" }
    if (-not (Test-Path -LiteralPath $CaCertificatePath)) { throw "CA certificate not found" }

    $api = Resolve-ResetApiAddress -Address $ResetApiIp
    $tokenInput = Read-ClientToken
    $token = $tokenInput.PlainText
    $secureToken = $tokenInput.SecureString
    $headers = $null
    try {
        New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
        Set-Acl -LiteralPath $InstallRoot -AclObject (New-RestrictedFileSystemAcl -Directory)
        New-Item -ItemType Directory -Path (Join-Path $InstallRoot "logs") -Force | Out-Null

        $installedScript = Join-Path $InstallRoot "Reset-And-Connect.ps1"
        $tokenPath = Join-Path $InstallRoot "client.token"
        $egsConfigPath = Join-Path $InstallRoot "egs-sync.json"
        Copy-Item -LiteralPath $ClientScriptPath -Destination $installedScript -Force
        Set-Acl -LiteralPath $installedScript -AclObject (New-RestrictedFileSystemAcl)
        [System.IO.File]::WriteAllText(
            $tokenPath,
            $token,
            (New-Object System.Text.UTF8Encoding($false))
        )
        Set-Acl -LiteralPath $tokenPath -AclObject (New-RestrictedFileSystemAcl)
        [ordered]@{
            schema_version = 2
            mode = $EpicGamesManifestSync.ToLowerInvariant()
        } | ConvertTo-Json | Set-Content -LiteralPath $egsConfigPath -Encoding UTF8
        Set-Acl -LiteralPath $egsConfigPath -AclObject (New-RestrictedFileSystemAcl)

        Import-Certificate -FilePath $CaCertificatePath `
            -CertStoreLocation "Cert:\LocalMachine\Root" | Out-Null
        Set-Service -Name MSiSCSI -StartupType Automatic
        Start-Service -Name MSiSCSI

        $headers = New-ClientRequestHeaders -ClientToken $token
        $client = Invoke-RestMethod -Method GET -Uri "$($api.BaseUrl)/v1/client" `
            -Headers $headers -TimeoutSec 30
        foreach ($session in @(Get-IscsiSession | Where-Object {
            $_.TargetNodeAddress -eq [string]$client.target_iqn -and $_.IsPersistent
        })) {
            Unregister-IscsiSession -SessionIdentifier $session.SessionIdentifier
        }

        $powerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
        $arguments = New-ResetScheduledTaskArguments -ScriptPath $installedScript `
            -BaseUrl $api.BaseUrl -ClientTokenPath $tokenPath
        $action = New-ScheduledTaskAction -Execute $powerShell -Argument $arguments
        $trigger = New-ScheduledTaskTrigger -AtStartup
        $trigger.Delay = "PT15S"
        $principalTask = New-ScheduledTaskPrincipal -UserId "SYSTEM" `
            -LogonType ServiceAccount -RunLevel Highest
        $taskLimitMinutes = if ($EpicGamesManifestSync -eq "Aggressive") { 20 } else { 5 }
        $settings = New-ScheduledTaskSettingsSet `
            -ExecutionTimeLimit (New-TimeSpan -Minutes $taskLimitMinutes) `
            -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew
        Register-ScheduledTask -TaskName "iSCSI Reset and Connect" -Action $action `
            -Trigger $trigger -Principal $principalTask -Settings $settings -Force | Out-Null

        Write-Host "Installed iSCSI reset client for Reset API $($api.Ip):8443."
        Write-Host "Epic Games manifest sync: $EpicGamesManifestSync."
        Write-Host "Reboot to run the first reset and non-persistent login."
    }
    finally {
        $headers = $null
        $token = $null
        $tokenInput = $null
        if ($null -ne $secureToken) {
            $secureToken.Dispose()
            $secureToken = $null
        }
    }
}

if ($MyInvocation.InvocationName -ne ".") {
    Invoke-IscsiResetClientInstall
}
