[CmdletBinding()]
param(
    [string]$ConfigPath = "C:\ProgramData\IscsiResetPublisher\publisher.json",
    [string]$TokenPath = "C:\ProgramData\IscsiResetPublisher\admin.token",
    [string]$PendingPath = "C:\ProgramData\IscsiResetPublisher\publish.pending.json",
    [string]$Confirmation = "",
    [string]$SimulationSourceIp = "",
    [switch]$AllowHttpForSimulation,
    [switch]$PassThruExitCode,
    [switch]$NoMain
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

function Normalize-PublisherDiskId {
    param([Parameter(Mandatory = $true)][string]$Value)
    $normalized = ($Value -replace "\s", "").ToLowerInvariant()
    if ($normalized.StartsWith("0x")) { return $normalized.Substring(2) }
    return $normalized
}

function Invoke-PublisherRequest {
    param(
        [Parameter(Mandatory = $true)][ValidateSet("GET", "POST")][string]$Method,
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$Token,
        [Parameter(Mandatory = $true)][string]$RequestId,
        [string]$CertificateThumbprint = "",
        [object]$Body = $null
    )
    $headers = @{ Authorization = "Bearer $Token"; "X-Request-ID" = $RequestId }
    if (-not [string]::IsNullOrWhiteSpace($script:SimulationSourceIp)) {
        $headers["X-Test-Source-IP"] = $script:SimulationSourceIp
    }
    $parameters = @{
        Method = $Method
        Uri = $Uri
        Headers = $headers
        TimeoutSec = 180
    }
    if (-not [string]::IsNullOrWhiteSpace($CertificateThumbprint)) {
        $parameters["CertificateThumbprint"] = $CertificateThumbprint
    }
    if ($null -ne $Body) {
        $parameters["Body"] = ($Body | ConvertTo-Json -Compress)
        $parameters["ContentType"] = "application/json"
    }
    return Invoke-RestMethod @parameters
}

function Get-PublisherHttpStatus {
    param([Parameter(Mandatory = $true)]$Exception)
    if ($Exception.Data.Contains("StatusCode")) {
        return [int]$Exception.Data["StatusCode"]
    }
    $responseProperty = $Exception.PSObject.Properties["Response"]
    if ($null -ne $responseProperty -and $null -ne $responseProperty.Value) {
        try { return [int]$responseProperty.Value.StatusCode } catch { return 0 }
    }
    return 0
}

function Invoke-StageWithRetry {
    param(
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [Parameter(Mandatory = $true)][string]$Token,
        [Parameter(Mandatory = $true)][string]$RequestId,
        [string]$CertificateThumbprint = "",
        [int]$TimeoutSeconds = 120
    )
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $delay = 2
    while ($true) {
        try {
            return Invoke-PublisherRequest `
                -Method POST `
                -Uri "$BaseUrl/v1/admin/releases/stage" `
                -Token $Token `
                -RequestId $RequestId `
                -CertificateThumbprint $CertificateThumbprint
        } catch {
            $status = Get-PublisherHttpStatus -Exception $_.Exception
            if (($status -notin @(409, 423, 503)) -or ([DateTime]::UtcNow -ge $deadline)) {
                throw
            }
            Start-Sleep -Seconds $delay
            $delay = [Math]::Min(10, $delay * 2)
        }
    }
}

function Get-PublisherSession {
    param([Parameter(Mandatory = $true)][string]$TargetIqn)
    return @(Get-IscsiSession | Where-Object { $_.TargetNodeAddress -eq $TargetIqn })
}

function Get-PublisherSessionDisks {
    param([Parameter(Mandatory = $true)]$Session)
    return @($Session | Get-Disk)
}

function Assert-PublisherDisks {
    param(
        [Parameter(Mandatory = $true)]$ExpectedVolumes,
        [Parameter(Mandatory = $true)]$Disks
    )
    if ($Disks.Count -ne $ExpectedVolumes.Count) {
        throw "Publisher session exposed $($Disks.Count) disks; expected $($ExpectedVolumes.Count)"
    }
    $matched = @()
    foreach ($expected in $ExpectedVolumes) {
        $expectedId = Normalize-PublisherDiskId ([string]$expected.disk_unique_id)
        $matches = @($Disks | Where-Object {
            (Normalize-PublisherDiskId ([string]$_.UniqueId)) -eq $expectedId
        })
        if ($matches.Count -ne 1) {
            throw "Expected exactly one publisher disk for NAA $expectedId"
        }
        $matched += $matches[0]
    }
    return $matched
}

function Set-PublisherDisksOffline {
    param([Parameter(Mandatory = $true)]$Disks)
    foreach ($disk in $Disks) {
        if (-not $disk.IsOffline) { Set-Disk -Number $disk.Number -IsOffline $true }
    }
    foreach ($disk in $Disks) {
        $current = Get-Disk -Number $disk.Number
        if (-not $current.IsOffline) { throw "Disk $($disk.Number) did not go offline" }
    }
}

function Ensure-PublisherPortal {
    param([Parameter(Mandatory = $true)]$Portal)
    $existing = @(Get-IscsiTargetPortal | Where-Object {
        $_.TargetPortalAddress -eq [string]$Portal.address -and
        $_.TargetPortalPortNumber -eq [int]$Portal.port
    })
    if ($existing.Count -eq 0) {
        New-IscsiTargetPortal `
            -TargetPortalAddress ([string]$Portal.address) `
            -TargetPortalPortNumber ([int]$Portal.port) | Out-Null
    }
}

function Connect-PublisherTarget {
    param(
        [Parameter(Mandatory = $true)]$Publisher,
        [Parameter(Mandatory = $true)]$ExpectedVolumes
    )
    Ensure-PublisherPortal -Portal $Publisher.portal
    Update-IscsiTarget -NodeAddress ([string]$Publisher.target_iqn) -ErrorAction SilentlyContinue | Out-Null
    $existingSessions = @(Get-PublisherSession -TargetIqn ([string]$Publisher.target_iqn))
    if ($existingSessions.Count -eq 0) {
        Connect-IscsiTarget `
            -NodeAddress ([string]$Publisher.target_iqn) `
            -TargetPortalAddress ([string]$Publisher.portal.address) `
            -TargetPortalPortNumber ([int]$Publisher.portal.port) `
            -IsPersistent $false `
            -IsMultipathEnabled $false `
            -AuthenticationType NONE | Out-Null
    } elseif ($existingSessions.Count -ne 1) {
        throw "Publisher target has $($existingSessions.Count) sessions; expected at most one"
    }
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        $sessions = @(Get-PublisherSession -TargetIqn ([string]$Publisher.target_iqn))
        if ($sessions.Count -eq 1) {
            $disks = @(Get-PublisherSessionDisks -Session $sessions[0])
            if ($disks.Count -eq $ExpectedVolumes.Count) {
                $matched = @(Assert-PublisherDisks -ExpectedVolumes $ExpectedVolumes -Disks $disks)
                foreach ($disk in $matched) {
                    if ($disk.IsOffline) { Set-Disk -Number $disk.Number -IsOffline $false }
                }
                return
            }
        }
        Start-Sleep -Seconds 1
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Publisher target did not reconnect with the expected disks"
}

function Save-PendingPublication {
    param([string]$Path, [string]$RequestId, [string]$Release = "")
    [ordered]@{
        request_id = $RequestId
        release = $Release
    } | ConvertTo-Json | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Invoke-PublisherMain {
    param([string]$PublisherConfigPath, [string]$AdminTokenPath, [string]$StatePath)
    $publisher = $null
    $token = ""
    $config = $null
    try {
        if (-not (Test-Path -LiteralPath $PublisherConfigPath)) { throw "Config file not found" }
        if (-not (Test-Path -LiteralPath $AdminTokenPath)) { throw "Admin token file not found" }
        $config = Get-Content -LiteralPath $PublisherConfigPath -Raw | ConvertFrom-Json
        $token = (Get-Content -LiteralPath $AdminTokenPath -Raw).Trim()
        $baseUrl = ([string]$config.api_base_url).TrimEnd("/")
        if ($baseUrl.StartsWith("http://") -and -not $script:AllowHttpForSimulation) {
            throw "Plain HTTP is permitted only in explicit simulation mode"
        }

        $pending = $null
        if (Test-Path -LiteralPath $StatePath) {
            $pending = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
        }
        $requestId = if ($null -ne $pending) {
            [string]$pending.request_id
        } else {
            [Guid]::NewGuid().ToString("D")
        }
        $publisher = Invoke-PublisherRequest `
            -Method GET `
            -Uri "$baseUrl/v1/admin/publisher" `
            -Token $token `
            -RequestId $requestId `
            -CertificateThumbprint ([string]$config.certificate_thumbprint)

        $releaseName = if ($null -ne $pending) { [string]$pending.release } else { "" }
        if ([string]::IsNullOrWhiteSpace($releaseName)) {
            if ($null -eq $pending) {
                $sessions = @(Get-PublisherSession -TargetIqn ([string]$publisher.target_iqn))
                if ($sessions.Count -ne 1) {
                    throw "A new publication requires exactly one connected master session"
                }
                $disks = @(Get-PublisherSessionDisks -Session $sessions[0])
                $matched = @(
                    Assert-PublisherDisks `
                        -ExpectedVolumes @($publisher.volumes) `
                        -Disks $disks
                )
                Set-PublisherDisksOffline -Disks $matched
                Disconnect-IscsiTarget `
                    -NodeAddress ([string]$publisher.target_iqn) `
                    -Confirm:$false
                Save-PendingPublication -Path $StatePath -RequestId $requestId
            }
            $staged = Invoke-StageWithRetry `
                -BaseUrl $baseUrl `
                -Token $token `
                -RequestId $requestId `
                -CertificateThumbprint ([string]$config.certificate_thumbprint)
            $releaseName = [string]$staged.release
            Save-PendingPublication -Path $StatePath -RequestId $requestId -Release $releaseName
        }

        Connect-PublisherTarget -Publisher $publisher -ExpectedVolumes @($publisher.volumes)

        $answer = $script:Confirmation
        if ([string]::IsNullOrWhiteSpace($answer)) {
            $answer = Read-Host "Type ACTIVATE $releaseName to activate the staged release"
        }
        if ($answer -ne "ACTIVATE $releaseName") {
            Write-Warning "Release $releaseName remains staged and inactive"
            return 2
        }

        $activateRequestId = [Guid]::NewGuid().ToString("D")
        Invoke-PublisherRequest `
            -Method POST `
            -Uri "$baseUrl/v1/admin/releases/$releaseName/activate" `
            -Token $token `
            -RequestId $activateRequestId `
            -CertificateThumbprint ([string]$config.certificate_thumbprint) `
            -Body @{ confirmation = "ACTIVATE $releaseName" } | Out-Null
        Remove-Item -LiteralPath $StatePath -Force
        Write-Host "Release activated: $releaseName"
        return 0
    } catch {
        Write-Warning $_.Exception.Message
        return 1
    }
}

if (-not $NoMain) {
    $exitCode = Invoke-PublisherMain `
        -PublisherConfigPath $ConfigPath `
        -AdminTokenPath $TokenPath `
        -StatePath $PendingPath
    if ($PassThruExitCode) { Write-Output $exitCode } else { exit $exitCode }
}
