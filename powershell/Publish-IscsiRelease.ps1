[CmdletBinding()]
param(
    [ValidateSet("Disconnect", "Reconnect")][string]$Action = "Disconnect",
    [string]$ManifestPath = "C:\ProgramData\IscsiResetPublisher\publisher.json",
    [string]$PendingPath = "C:\ProgramData\IscsiResetPublisher\publisher.pending.json",
    [string]$EgsSyncConfigPath = (Join-Path $PSScriptRoot "egs-sync.json"),
    [string]$EgsManifestDirectory = "C:\ProgramData\Epic\EpicGamesLauncher\Data\Manifests",
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

function Get-EgsManifestSyncEnabled {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $config = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ([int]$config.schema_version -ne 1 -or $config.enabled -isnot [bool]) {
        throw "Epic Games manifest sync config is invalid: $Path"
    }
    return [bool]$config.enabled
}

function Get-EgsSha256Hex {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return (($algorithm.ComputeHash($Bytes) | ForEach-Object {
            $_.ToString("x2")
        }) -join "")
    } finally {
        $algorithm.Dispose()
    }
}

function ConvertTo-EgsCanonicalPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { throw "Epic Games path is empty" }
    $candidate = $Path.Trim().Replace("/", "\")
    if ($candidate -match "^[A-Za-z]:\\") {
        if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
            return [IO.Path]::GetFullPath($candidate).TrimEnd([char[]]@(92))
        }
        return $candidate.TrimEnd([char[]]@(92))
    }
    $separators = [char[]]@(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    )
    return [IO.Path]::GetFullPath($Path).TrimEnd($separators)
}

function Test-EgsPathWithinRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$RootPath
    )
    $candidate = ConvertTo-EgsCanonicalPath $Path
    $root = ConvertTo-EgsCanonicalPath $RootPath
    if ($candidate.Equals($root, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    $separator = if ($candidate -match "^[A-Za-z]:\\") { "\" } else {
        [IO.Path]::DirectorySeparatorChar
    }
    return $candidate.StartsWith(
        $root.TrimEnd([char[]]@(92, 47)) + $separator,
        [StringComparison]::OrdinalIgnoreCase
    )
}

function Get-RequiredEgsString {
    param(
        [Parameter(Mandatory = $true)]$Item,
        [Parameter(Mandatory = $true)][string]$Name
    )
    if ($Item.PSObject.Properties.Name -notcontains $Name) {
        throw "Epic Games manifest is missing $Name"
    }
    $value = [string]$Item.$Name
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "Epic Games manifest has an empty $Name"
    }
    return $value
}

function Test-EgsInstallationId {
    param([Parameter(Mandatory = $true)][string]$Value)
    return $Value -match "^[0-9A-Fa-f]{16,64}$"
}

function Stop-EgsLauncherProcesses {
    param([int]$GraceSeconds = 15)
    $names = @("EpicGamesLauncher", "EpicWebHelper")
    $launcher = @(Get-Process -Name $names -ErrorAction SilentlyContinue)
    foreach ($process in @($launcher | Where-Object { $_.ProcessName -eq "EpicGamesLauncher" })) {
        try { $process.CloseMainWindow() | Out-Null } catch { }
    }

    for ($second = 0; $second -lt $GraceSeconds; $second++) {
        if (@(Get-Process -Name $names -ErrorAction SilentlyContinue).Count -eq 0) { return }
        Start-Sleep -Seconds 1
    }

    foreach ($process in @(Get-Process -Name $names -ErrorAction SilentlyContinue)) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 1
    if (@(Get-Process -Name $names -ErrorAction SilentlyContinue).Count -ne 0) {
        throw "Epic Games Launcher processes could not be stopped"
    }
}

function Assert-EgsLauncherStopped {
    $running = @(Get-Process -Name @("EpicGamesLauncher", "EpicWebHelper") `
        -ErrorAction SilentlyContinue)
    if ($running.Count -ne 0) { throw "Epic Games Launcher restarted during manifest export" }
}

function Get-PublisherEgsVolumeMappings {
    param(
        [Parameter(Mandatory = $true)]$ExpectedVolumes,
        [Parameter(Mandatory = $true)]$Disks
    )
    $mappings = @()
    foreach ($expected in $ExpectedVolumes) {
        $expectedId = Normalize-PublisherDiskId ([string]$expected.disk_unique_id)
        $matches = @($Disks | Where-Object {
            (Normalize-PublisherDiskId ([string]$_.UniqueId)) -eq $expectedId
        })
        if ($matches.Count -ne 1) {
            throw "Expected exactly one Publisher disk for EGS volume $($expected.name)"
        }
        $partitions = @(Get-Partition -DiskNumber $matches[0].Number | Where-Object {
            $_.Type -notin @("Reserved", "System", "Recovery")
        })
        if ($partitions.Count -ne 1 -or
            [string]::IsNullOrWhiteSpace([string]$partitions[0].DriveLetter)) {
            throw "Publisher volume $($expected.name) must have one mounted data partition"
        }
        $letter = ([string]$partitions[0].DriveLetter).ToUpperInvariant()
        if ($letter -notmatch "^[A-Z]$") {
            throw "Publisher volume $($expected.name) has an invalid drive letter"
        }
        $mappings += [pscustomobject]@{
            Name = [string]$expected.name
            Disk = $matches[0]
            RootPath = "$letter`:\"
        }
    }
    return $mappings
}

function Assert-PublisherEgsItem {
    param(
        [Parameter(Mandatory = $true)]$Item,
        [Parameter(Mandatory = $true)][string]$ItemPath,
        [Parameter(Mandatory = $true)]$VolumeMapping
    )
    $appName = Get-RequiredEgsString -Item $Item -Name "AppName"
    $guid = Get-RequiredEgsString -Item $Item -Name "InstallationGuid"
    if (-not (Test-EgsInstallationId $guid)) {
        throw "$appName has an invalid Epic installation identifier"
    }
    if (-not ([IO.Path]::GetFileName($ItemPath)).Equals(
        "$guid.item", [StringComparison]::OrdinalIgnoreCase
    )) {
        throw "$appName .item filename does not match InstallationGuid"
    }
    Get-RequiredEgsString -Item $Item -Name "AppVersionString" | Out-Null
    if ($Item.PSObject.Properties.Name -notcontains "InstallTags") {
        throw "$appName manifest has no InstallTags"
    }

    $installLocation = ConvertTo-EgsCanonicalPath (
        Get-RequiredEgsString -Item $Item -Name "InstallLocation"
    )
    if (-not (Test-EgsPathWithinRoot -Path $installLocation -RootPath $VolumeMapping.RootPath)) {
        throw "$appName is outside Publisher volume $($VolumeMapping.Name)"
    }
    if (-not (Test-Path -LiteralPath $installLocation -PathType Container)) {
        throw "$appName install directory does not exist"
    }
    $egstore = ConvertTo-EgsCanonicalPath (Join-Path $installLocation ".egstore")
    $manifestLocation = ConvertTo-EgsCanonicalPath (
        Get-RequiredEgsString -Item $Item -Name "ManifestLocation"
    )
    if (-not $manifestLocation.Equals($egstore, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$appName ManifestLocation does not match its .egstore directory"
    }
    $stagingLocation = ConvertTo-EgsCanonicalPath (
        Get-RequiredEgsString -Item $Item -Name "StagingLocation"
    )
    $expectedStaging = ConvertTo-EgsCanonicalPath (Join-Path $egstore "bps")
    if (-not $stagingLocation.Equals($expectedStaging, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$appName StagingLocation does not match its .egstore directory"
    }

    $binaryManifest = Join-Path $egstore "$guid.manifest"
    $component = Join-Path $egstore "$guid.mancpn"
    if (-not (Test-Path -LiteralPath $binaryManifest -PathType Leaf)) {
        throw "$appName .egstore binary manifest is missing"
    }
    if ((Get-Item -LiteralPath $binaryManifest).Length -le 0) {
        throw "$appName binary manifest is empty"
    }
    if (Test-Path -LiteralPath $component -PathType Leaf) {
        $componentData = Get-Content -LiteralPath $component -Raw | ConvertFrom-Json
        if ([string]$componentData.AppName -ne $appName) {
            throw "$appName .mancpn AppName does not match"
        }
    }

    if ($Item.PSObject.Properties.Name -contains "LaunchExecutable" -and
        -not [string]::IsNullOrWhiteSpace([string]$Item.LaunchExecutable)) {
        $launchPath = [string]$Item.LaunchExecutable
        if (-not [IO.Path]::IsPathRooted($launchPath)) {
            $launchPath = Join-Path $installLocation $launchPath
        }
        if (-not (Test-Path -LiteralPath $launchPath -PathType Leaf)) {
            throw "$appName launch executable does not exist"
        }
    }
}

function Assert-PublisherEgsBundle {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ConfigRevision,
        [Parameter(Mandatory = $true)][string]$VolumeName
    )
    $bundle = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ([int]$bundle.schema_version -ne 1 -or
        [string]$bundle.config_revision -ne $ConfigRevision -or
        [string]$bundle.volume_name -ne $VolumeName -or
        $bundle.PSObject.Properties.Name -notcontains "manifests") {
        throw "Epic Games bundle verification failed for volume $VolumeName"
    }
    foreach ($entry in @($bundle.manifests)) {
        $bytes = [Convert]::FromBase64String([string]$entry.payload_base64)
        if ((Get-EgsSha256Hex $bytes) -ne [string]$entry.sha256) {
            throw "Epic Games bundle hash verification failed for $($entry.app_name)"
        }
        $item = [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json
        if ([string]$item.AppName -ne [string]$entry.app_name -or
            [string]$item.InstallationGuid -ne [string]$entry.installation_guid) {
            throw "Epic Games bundle identity verification failed"
        }
    }
}

function Write-PublisherEgsBundleAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Bundle
    )
    $directory = Split-Path $Path -Parent
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $temporary = Join-Path $directory (".egs-bundle-" + [Guid]::NewGuid().ToString("N") + ".tmp")
    $backup = Join-Path $directory (".egs-bundle-" + [Guid]::NewGuid().ToString("N") + ".bak")
    try {
        $json = $Bundle | ConvertTo-Json -Depth 8
        [IO.File]::WriteAllText($temporary, $json, (New-Object Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $Path) {
            [IO.File]::Replace($temporary, $Path, $backup)
            Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
        } else {
            [IO.File]::Move($temporary, $Path)
        }
    } finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    }
}

function Export-PublisherEgsBundles {
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)]$VolumeMappings,
        [Parameter(Mandatory = $true)][string]$ManifestDirectory
    )
    if (-not (Test-Path -LiteralPath $ManifestDirectory -PathType Container)) {
        throw "Epic Games manifest directory does not exist: $ManifestDirectory"
    }
    Assert-EgsLauncherStopped
    $byVolume = @{}
    foreach ($mapping in $VolumeMappings) { $byVolume[$mapping.Name] = @() }
    $seenApps = @{}

    foreach ($file in @(Get-ChildItem -LiteralPath $ManifestDirectory -Filter "*.item" -File | Sort-Object Name)) {
        $bytes = [IO.File]::ReadAllBytes($file.FullName)
        try {
            $item = [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json
        } catch {
            throw "Epic Games manifest is not valid JSON: $($file.FullName)"
        }
        $installLocation = ConvertTo-EgsCanonicalPath (
            Get-RequiredEgsString -Item $item -Name "InstallLocation"
        )
        $mapping = @($VolumeMappings | Where-Object {
            Test-EgsPathWithinRoot -Path $installLocation -RootPath $_.RootPath
        })
        if ($mapping.Count -eq 0) { continue }
        if ($mapping.Count -ne 1) {
            throw "Epic Games manifest maps to more than one Publisher volume"
        }
        Assert-PublisherEgsItem -Item $item -ItemPath $file.FullName -VolumeMapping $mapping[0]
        $appName = [string]$item.AppName
        if ($seenApps.ContainsKey($appName)) {
            throw "Duplicate Epic Games AppName on Publisher volumes: $appName"
        }
        $seenApps[$appName] = $true
        $entry = [ordered]@{
            app_name = $appName
            installation_guid = [string]$item.InstallationGuid
            sha256 = Get-EgsSha256Hex $bytes
            payload_base64 = [Convert]::ToBase64String($bytes)
        }
        $byVolume[$mapping[0].Name] = @($byVolume[$mapping[0].Name]) + $entry
    }

    foreach ($mapping in $VolumeMappings) {
        $bundlePath = Join-Path $mapping.RootPath ".iscsi-reset\egs-manifests.v1.json"
        $bundle = [ordered]@{
            schema_version = 1
            config_revision = [string]$Manifest.config_revision
            volume_name = [string]$mapping.Name
            manifests = @($byVolume[$mapping.Name] | Sort-Object app_name)
        }
        Write-PublisherEgsBundleAtomic -Path $bundlePath -Bundle $bundle
    }
    foreach ($mapping in $VolumeMappings) {
        $bundlePath = Join-Path $mapping.RootPath ".iscsi-reset\egs-manifests.v1.json"
        Assert-PublisherEgsBundle -Path $bundlePath `
            -ConfigRevision ([string]$Manifest.config_revision) -VolumeName $mapping.Name
    }
    Assert-EgsLauncherStopped
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

function Wait-PublisherTargetDiscovery {
    param(
        [Parameter(Mandatory = $true)][string]$TargetIqn,
        [Parameter(Mandatory = $true)]$Portal,
        [int]$MaxAttempts = 60,
        [int]$DelaySeconds = 1
    )
    if ($MaxAttempts -lt 1) { throw "MaxAttempts must be at least one" }
    if ($DelaySeconds -lt 0) { throw "DelaySeconds must not be negative" }

    $lastError = ""
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            Update-IscsiTargetPortal `
                -TargetPortalAddress ([string]$Portal.address) `
                -TargetPortalPortNumber ([int]$Portal.port) | Out-Null
        } catch {
            $lastError = $_.Exception.Message
        }

        try {
            $targets = @(Get-IscsiTarget | Where-Object {
                [string]$_.NodeAddress -eq $TargetIqn
            })
            if ($targets.Count -gt 0) { return $targets[0] }
        } catch {
            $lastError = $_.Exception.Message
        }

        if ($attempt -lt $MaxAttempts) {
            Start-Sleep -Seconds $DelaySeconds
        }
    }

    $message = "iSCSI target was not discovered after $MaxAttempts attempts: $TargetIqn"
    if (-not [string]::IsNullOrWhiteSpace($lastError)) {
        $message += ". Last discovery error: $lastError"
    }
    throw $message
}

function Connect-PublisherTarget {
    param([Parameter(Mandatory = $true)]$Manifest)
    $sessions = @(Get-PublisherSession -TargetIqn ([string]$Manifest.target_iqn))
    if ($sessions.Count -eq 0) {
        Ensure-PublisherPortal -Portal $Manifest.portal
        Wait-PublisherTargetDiscovery -TargetIqn ([string]$Manifest.target_iqn) `
            -Portal $Manifest.portal | Out-Null
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
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)][string]$StatePath,
        [bool]$EgsSyncEnabled = $false,
        [string]$EpicManifestDirectory = "C:\ProgramData\Epic\EpicGamesLauncher\Data\Manifests"
    )
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
    if ($EgsSyncEnabled) {
        Stop-EgsLauncherProcesses
        $volumeMappings = @(Get-PublisherEgsVolumeMappings `
            -ExpectedVolumes @($Manifest.volumes) -Disks $matched)
        Export-PublisherEgsBundles -Manifest $Manifest -VolumeMappings $volumeMappings `
            -ManifestDirectory $EpicManifestDirectory
    }
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
        [Parameter(Mandatory = $true)][string]$StatePath,
        [Parameter(Mandatory = $true)][string]$SyncConfigPath,
        [Parameter(Mandatory = $true)][string]$EpicManifestDirectory
    )
    try {
        $manifest = Read-PublisherManifest -Path $PublisherManifestPath
        if ($RequestedAction -eq "Disconnect") {
            $egsSyncEnabled = Get-EgsManifestSyncEnabled -Path $SyncConfigPath
            Invoke-PublisherDisconnect -Manifest $manifest -StatePath $StatePath `
                -EgsSyncEnabled $egsSyncEnabled -EpicManifestDirectory $EpicManifestDirectory
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
        -StatePath $PendingPath `
        -SyncConfigPath $EgsSyncConfigPath `
        -EpicManifestDirectory $EgsManifestDirectory
    if ($PassThruExitCode) { Write-Output $exitCode } else { exit $exitCode }
}
