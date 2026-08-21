[CmdletBinding()]
param(
    [ValidateSet("Disconnect", "Reconnect")][string]$Action = "Disconnect",
    [string]$ManifestPath = "C:\ProgramData\IscsiResetPublisher\publisher.json",
    [string]$PendingPath = "C:\ProgramData\IscsiResetPublisher\publisher.pending.json",
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

function Read-PublisherManifest {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Publisher manifest not found: $Path" }
    $manifest = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ([int]$manifest.schema_version -ne 1) { throw "Unsupported publisher manifest schema" }
    if ([string]::IsNullOrWhiteSpace([string]$manifest.config_revision)) {
        throw "Publisher manifest has no config revision"
    }
    if ([string]::IsNullOrWhiteSpace([string]$manifest.target_iqn)) {
        throw "Publisher manifest has no target IQN"
    }
    if ($null -eq $manifest.portal -or
        [string]::IsNullOrWhiteSpace([string]$manifest.portal.address) -or
        [int]$manifest.portal.port -lt 1) {
        throw "Publisher manifest has an invalid portal"
    }
    $volumes = @($manifest.volumes)
    if ($volumes.Count -eq 0) { throw "Publisher manifest has no volumes" }
    $ids = @($volumes | ForEach-Object {
        Normalize-PublisherDiskId ([string]$_.disk_unique_id)
    })
    if (@($ids | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
        throw "Publisher manifest contains an empty disk ID"
    }
    if (@($ids | Select-Object -Unique).Count -ne $ids.Count) {
        throw "Publisher manifest contains duplicate disk IDs"
    }
    return $manifest
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

function Save-PublisherPending {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Manifest
    )
    $directory = Split-Path $Path -Parent
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $temporary = Join-Path $directory (".publisher-pending-" + [Guid]::NewGuid().ToString("N") + ".tmp")
    [ordered]@{
        schema_version = 1
        config_revision = [string]$Manifest.config_revision
        target_iqn = [string]$Manifest.target_iqn
        disk_unique_ids = @($Manifest.volumes | ForEach-Object {
            Normalize-PublisherDiskId ([string]$_.disk_unique_id)
        } | Sort-Object)
        created_at = [DateTime]::UtcNow.ToString("o")
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $temporary -Encoding UTF8
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Assert-PublisherPending {
    param(
        [Parameter(Mandatory = $true)]$Pending,
        [Parameter(Mandatory = $true)]$Manifest
    )
    if ([int]$Pending.schema_version -ne 1 -or
        [string]$Pending.config_revision -ne [string]$Manifest.config_revision -or
        [string]$Pending.target_iqn -ne [string]$Manifest.target_iqn) {
        throw "Pending state does not match the publisher manifest revision"
    }
    $pendingIds = @($Pending.disk_unique_ids | ForEach-Object {
        Normalize-PublisherDiskId ([string]$_)
    } | Sort-Object)
    $manifestIds = @($Manifest.volumes | ForEach-Object {
        Normalize-PublisherDiskId ([string]$_.disk_unique_id)
    } | Sort-Object)
    if (($pendingIds -join ",") -ne ($manifestIds -join ",")) {
        throw "Pending state disk IDs do not match the publisher manifest"
    }
}

function Set-PublisherDisksOffline {
    param([Parameter(Mandatory = $true)]$Disks)
    $errors = @()
    foreach ($disk in $Disks) {
        try {
            if (-not $disk.IsOffline) { Set-Disk -Number $disk.Number -IsOffline $true }
        } catch {
            $errors += "Disk $($disk.Number): $($_.Exception.Message)"
        }
    }
    foreach ($disk in $Disks) {
        try {
            $current = Get-Disk -Number $disk.Number
            if (-not $current.IsOffline) { $errors += "Disk $($disk.Number) did not go offline" }
        } catch {
            $errors += "Disk $($disk.Number) verification failed"
        }
    }
    if ($errors.Count -gt 0) { throw ($errors -join "; ") }
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
    param([Parameter(Mandatory = $true)]$Manifest)
    Ensure-PublisherPortal -Portal $Manifest.portal
    Update-IscsiTarget -NodeAddress ([string]$Manifest.target_iqn) -ErrorAction SilentlyContinue | Out-Null
    $sessions = @(Get-PublisherSession -TargetIqn ([string]$Manifest.target_iqn))
    if ($sessions.Count -eq 0) {
        Connect-IscsiTarget `
            -NodeAddress ([string]$Manifest.target_iqn) `
            -TargetPortalAddress ([string]$Manifest.portal.address) `
            -TargetPortalPortNumber ([int]$Manifest.portal.port) `
            -IsPersistent $false `
            -IsMultipathEnabled $false `
            -AuthenticationType NONE | Out-Null
    } elseif ($sessions.Count -ne 1) {
        throw "Publisher target has $($sessions.Count) sessions; expected at most one"
    }

    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        $sessions = @(Get-PublisherSession -TargetIqn ([string]$Manifest.target_iqn))
        if ($sessions.Count -eq 1) {
            $disks = @(Get-PublisherSessionDisks -Session $sessions[0])
            if ($disks.Count -eq @($Manifest.volumes).Count) {
                return @(Assert-PublisherDisks -ExpectedVolumes @($Manifest.volumes) -Disks $disks)
            }
        }
        Start-Sleep -Seconds 1
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Publisher target did not reconnect with the expected disks"
}

function Invoke-PublisherDisconnect {
    param([Parameter(Mandatory = $true)]$Manifest, [Parameter(Mandatory = $true)][string]$StatePath)
    if (Test-Path -LiteralPath $StatePath) {
        $pending = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
        Assert-PublisherPending -Pending $pending -Manifest $Manifest
        if (@(Get-PublisherSession -TargetIqn ([string]$Manifest.target_iqn)).Count -eq 0) {
            return
        }
        throw "Pending state exists but Publisher is still connected; recover manually"
    }
    $sessions = @(Get-PublisherSession -TargetIqn ([string]$Manifest.target_iqn))
    if ($sessions.Count -ne 1) { throw "Disconnect requires exactly one Publisher session" }
    $disks = @(Get-PublisherSessionDisks -Session $sessions[0])
    $matched = @(Assert-PublisherDisks -ExpectedVolumes @($Manifest.volumes) -Disks $disks)
    Save-PublisherPending -Path $StatePath -Manifest $Manifest
    Set-PublisherDisksOffline -Disks $matched
    Disconnect-IscsiTarget -NodeAddress ([string]$Manifest.target_iqn) -Confirm:$false
    if (@(Get-PublisherSession -TargetIqn ([string]$Manifest.target_iqn)).Count -ne 0) {
        throw "Publisher target did not disconnect"
    }
}

function Invoke-PublisherReconnect {
    param([Parameter(Mandatory = $true)]$Manifest, [Parameter(Mandatory = $true)][string]$StatePath)
    if (-not (Test-Path -LiteralPath $StatePath)) { throw "Publisher pending state not found" }
    $pending = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
    Assert-PublisherPending -Pending $pending -Manifest $Manifest
    $matched = @(Connect-PublisherTarget -Manifest $Manifest)
    foreach ($disk in $matched) {
        if ($disk.IsOffline) { Set-Disk -Number $disk.Number -IsOffline $false }
    }
    foreach ($disk in $matched) {
        if ((Get-Disk -Number $disk.Number).IsOffline) {
            throw "Disk $($disk.Number) did not come online"
        }
    }
    Remove-Item -LiteralPath $StatePath -Force
}

function Invoke-PublisherMain {
    param(
        [Parameter(Mandatory = $true)][ValidateSet("Disconnect", "Reconnect")][string]$RequestedAction,
        [Parameter(Mandatory = $true)][string]$PublisherManifestPath,
        [Parameter(Mandatory = $true)][string]$StatePath
    )
    try {
        $manifest = Read-PublisherManifest -Path $PublisherManifestPath
        if ($RequestedAction -eq "Disconnect") {
            Invoke-PublisherDisconnect -Manifest $manifest -StatePath $StatePath
            Write-Host "Publisher disconnected. Create and activate the release in the management UI."
        } else {
            Invoke-PublisherReconnect -Manifest $manifest -StatePath $StatePath
            Write-Host "Publisher reconnected and exact disks verified."
        }
        return 0
    } catch {
        Write-Warning $_.Exception.Message
        return 1
    }
}

if (-not $NoMain) {
    $exitCode = Invoke-PublisherMain `
        -RequestedAction $Action `
        -PublisherManifestPath $ManifestPath `
        -StatePath $PendingPath
    if ($PassThruExitCode) { Write-Output $exitCode } else { exit $exitCode }
}
