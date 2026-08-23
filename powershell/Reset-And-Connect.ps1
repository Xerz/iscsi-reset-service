[CmdletBinding()]
param(
    [string]$ApiBaseUrl = "https://10.20.40.10:8443",
    [string]$TokenPath = "C:\ProgramData\IscsiReset\client.token",
    [string]$EgsSyncConfigPath = "",
    [int]$WaitTimeoutSeconds = 120,
    [string]$SimulationStatePath = "",
    [string]$SimulationSourceIp = "",
    [switch]$AllowHttpForSimulation,
    [switch]$PassThruExitCode,
    [switch]$NoMain
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
$script:DefaultEgsSyncConfigPath = Join-Path $PSScriptRoot "egs-sync.json"

function Resolve-EgsSyncConfigPath {
    param([AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $script:DefaultEgsSyncConfigPath
    }
    return $Path
}

$EgsSyncConfigPath = Resolve-EgsSyncConfigPath -Path $EgsSyncConfigPath

function Write-ResetLog {
    param(
        [Parameter(Mandatory = $true)][string]$Level,
        [Parameter(Mandatory = $true)][string]$Event,
        [Parameter(Mandatory = $true)][string]$RequestId,
        [string]$Message = "",
        [string]$LogPath = "",
        [hashtable]$Details = @{}
    )
    try {
        if ([string]::IsNullOrWhiteSpace($LogPath)) {
            if (-not [string]::IsNullOrWhiteSpace($script:SimulationStatePath)) {
                $LogPath = Join-Path (Split-Path $script:SimulationStatePath -Parent) "client.log.jsonl"
            } else {
                $LogPath = "C:\ProgramData\IscsiReset\logs\reset.jsonl"
            }
        }
        $directory = Split-Path $LogPath -Parent
        if (-not (Test-Path -LiteralPath $directory)) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
        }
        $record = [ordered]@{
            timestamp = [DateTime]::UtcNow.ToString("o")
            level = $Level
            event = $Event
            request_id = $RequestId
            message = $Message
        }
        foreach ($key in @($Details.Keys | Sort-Object)) {
            if (-not $record.Contains($key)) {
                $record[$key] = $Details[$key]
            }
        }
        $record | ConvertTo-Json -Compress | Add-Content -LiteralPath $LogPath -Encoding UTF8
    } catch {
        # Local diagnostics must never change the storage safety outcome.
    }
}

function Normalize-DiskId {
    param([Parameter(Mandatory = $true)][string]$Value)
    $normalized = ($Value -replace "\s", "").ToLowerInvariant()
    if ($normalized.StartsWith("0x")) {
        return $normalized.Substring(2)
    }
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

function ConvertFrom-EgsJsonBytes {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)
    $json = [Text.Encoding]::UTF8.GetString($Bytes)
    if ($json.Length -gt 0 -and [int]$json[0] -eq 0xFEFF) {
        $json = $json.Substring(1)
    }
    return (ConvertFrom-Json -InputObject $json)
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
    if ($running.Count -ne 0) { throw "Epic Games Launcher restarted during manifest sync" }
}

function New-ApiException {
    param([int]$StatusCode, [string]$Code, [string]$Message)
    $exception = New-Object System.Exception($Message)
    $exception.Data["StatusCode"] = $StatusCode
    $exception.Data["Code"] = $Code
    return $exception
}

function Invoke-ResetRequest {
    param(
        [Parameter(Mandatory = $true)][ValidateSet("GET", "POST")][string]$Method,
        [Parameter(Mandatory = $true)][string]$Uri,
        [string]$Token = "",
        [Parameter(Mandatory = $true)][string]$RequestId,
        [int]$TimeoutSec = 180
    )
    $headers = @{ "X-Request-ID" = $RequestId }
    if (-not [string]::IsNullOrWhiteSpace($Token)) {
        $headers["Authorization"] = "Bearer $Token"
    }
    if (-not [string]::IsNullOrWhiteSpace($script:SimulationStatePath) -and
        -not [string]::IsNullOrWhiteSpace($script:SimulationSourceIp)) {
        $headers["X-Test-Source-IP"] = $script:SimulationSourceIp
    }
    try {
        return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers -TimeoutSec $TimeoutSec
    } catch {
        $statusCode = 0
        $code = "NETWORK_ERROR"
        $message = $_.Exception.Message
        if ($null -ne $_.Exception.Response) {
            try { $statusCode = [int]$_.Exception.Response.StatusCode } catch { $statusCode = 0 }
            try {
                $stream = $_.Exception.Response.GetResponseStream()
                $reader = New-Object System.IO.StreamReader($stream)
                $payload = $reader.ReadToEnd() | ConvertFrom-Json
                if ($null -ne $payload.error) {
                    $code = [string]$payload.error.code
                    $message = [string]$payload.error.message
                }
            } catch {
                # Preserve the original HTTP error when the body is not JSON.
            }
        }
        throw (New-ApiException -StatusCode $statusCode -Code $code -Message $message)
    }
}

function Wait-ResetApi {
    param(
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [Parameter(Mandatory = $true)][string]$RequestId,
        [int]$TimeoutSeconds = 120
    )
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $delay = 2
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            return Invoke-ResetRequest -Method GET -Uri "$BaseUrl/healthz" `
                -RequestId $RequestId -TimeoutSec 5
        } catch {
            Start-Sleep -Seconds $delay
            $delay = [Math]::Min(10, $delay * 2)
        }
    }
    throw (New-ApiException -StatusCode 0 -Code "API_TIMEOUT" -Message "Reset API did not become reachable")
}

function Invoke-PrepareWithRetry {
    param(
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [Parameter(Mandatory = $true)][string]$Token,
        [Parameter(Mandatory = $true)][string]$RequestId,
        [int]$TimeoutSeconds = 120
    )
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $delay = 2
    while ($true) {
        try {
            return Invoke-ResetRequest -Method POST -Uri "$BaseUrl/v1/prepare" -Token $Token -RequestId $RequestId
        } catch {
            $status = [int]$_.Exception.Data["StatusCode"]
            if (($status -notin @(409, 423, 503)) -or ([DateTime]::UtcNow -ge $deadline)) {
                throw
            }
            Start-Sleep -Seconds $delay
            $delay = [Math]::Min(10, $delay * 2)
        }
    }
}

function Read-SimulationState {
    if (-not (Test-Path -LiteralPath $script:SimulationStatePath)) {
        throw "Simulation state file does not exist: $script:SimulationStatePath"
    }
    return Get-Content -LiteralPath $script:SimulationStatePath -Raw | ConvertFrom-Json
}

function Save-SimulationState {
    param([Parameter(Mandatory = $true)]$State)
    $State | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:SimulationStatePath -Encoding UTF8
}

function Get-ResetSessions {
    param([Parameter(Mandatory = $true)][string]$TargetIqn)
    if (-not [string]::IsNullOrWhiteSpace($script:SimulationStatePath)) {
        $state = Read-SimulationState
        return @($state.sessions | Where-Object { $_.target_iqn -eq $TargetIqn })
    }
    return @(Get-IscsiSession | Where-Object { $_.TargetNodeAddress -eq $TargetIqn })
}

function Ensure-ResetPortal {
    param([Parameter(Mandatory = $true)]$Portal)
    if (-not [string]::IsNullOrWhiteSpace($script:SimulationStatePath)) { return }
    $existing = @(Get-IscsiTargetPortal | Where-Object {
        $_.TargetPortalAddress -eq [string]$Portal.address -and
        $_.TargetPortalPortNumber -eq [int]$Portal.port
    })
    if ($existing.Count -eq 0) {
        New-IscsiTargetPortal -TargetPortalAddress ([string]$Portal.address) -TargetPortalPortNumber ([int]$Portal.port) | Out-Null
    }
}

function Wait-ResetTargetDiscovery {
    param(
        [Parameter(Mandatory = $true)][string]$TargetIqn,
        [Parameter(Mandatory = $true)]$Portal,
        [Parameter(Mandatory = $true)][string]$RequestId,
        [int]$MaxAttempts = 60,
        [int]$DelaySeconds = 1
    )
    if ($MaxAttempts -lt 1) { throw "MaxAttempts must be at least one" }
    if ($DelaySeconds -lt 0) { throw "DelaySeconds must not be negative" }

    $startedAt = [DateTime]::UtcNow
    Write-ResetProgress -RequestId $RequestId -Event "target_discovery_started" `
        -Message "Waiting for the exact iSCSI target to appear" -Details @{
            target_iqn = $TargetIqn
            portal_address = [string]$Portal.address
            portal_port = [int]$Portal.port
            max_attempts = $MaxAttempts
        }

    if (-not [string]::IsNullOrWhiteSpace($script:SimulationStatePath)) {
        Write-ResetProgress -RequestId $RequestId -Event "target_discovered" `
            -Message "The exact iSCSI target is available" -Details @{
                target_iqn = $TargetIqn
                attempts = 1
                elapsed_seconds = 0
            }
        return [pscustomobject]@{ NodeAddress = $TargetIqn; Simulation = $true }
    }

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
            if ($targets.Count -gt 0) {
                $elapsed = [int][Math]::Floor(
                    ([DateTime]::UtcNow - $startedAt).TotalSeconds
                )
                Write-ResetProgress -RequestId $RequestId -Event "target_discovered" `
                    -Message "The exact iSCSI target is available" -Details @{
                        target_iqn = $TargetIqn
                        attempts = $attempt
                        elapsed_seconds = $elapsed
                    }
                return $targets[0]
            }
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
    throw (New-ApiException -StatusCode 0 -Code "TARGET_DISCOVERY_TIMEOUT" -Message $message)
}

function Connect-ResetTarget {
    param(
        [Parameter(Mandatory = $true)][string]$TargetIqn,
        [Parameter(Mandatory = $true)]$Portal
    )
    if (-not [string]::IsNullOrWhiteSpace($script:SimulationStatePath)) {
        $state = Read-SimulationState
        $sessions = @($state.sessions)
        $sessions += [pscustomobject]@{ target_iqn = $TargetIqn; persistent = $false }
        $state.sessions = $sessions
        Save-SimulationState $state
        return [pscustomobject]@{ TargetNodeAddress = $TargetIqn; Simulation = $true }
    }
    Connect-IscsiTarget -NodeAddress $TargetIqn `
        -TargetPortalAddress ([string]$Portal.address) `
        -TargetPortalPortNumber ([int]$Portal.port) `
        -IsPersistent $false `
        -IsMultipathEnabled $false `
        -AuthenticationType NONE | Out-Null
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        $session = @(Get-ResetSessions -TargetIqn $TargetIqn) | Select-Object -First 1
        if ($null -ne $session) { return $session }
        Start-Sleep -Seconds 1
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "iSCSI session did not appear: $TargetIqn"
}

function Disconnect-ResetTarget {
    param([Parameter(Mandatory = $true)][string]$TargetIqn)
    if (-not [string]::IsNullOrWhiteSpace($script:SimulationStatePath)) {
        $state = Read-SimulationState
        $state.sessions = @($state.sessions | Where-Object { $_.target_iqn -ne $TargetIqn })
        Save-SimulationState $state
        return
    }
    Disconnect-IscsiTarget -NodeAddress $TargetIqn -Confirm:$false -ErrorAction SilentlyContinue
}

function Get-ResetSessionDisks {
    param([Parameter(Mandatory = $true)]$Session)
    if (-not [string]::IsNullOrWhiteSpace($script:SimulationStatePath)) {
        $state = Read-SimulationState
        return @($state.disks | Where-Object { $_.target_iqn -eq $Session.TargetNodeAddress })
    }
    return @($Session | Get-Disk)
}

function Wait-ResetSessionDisks {
    param(
        [Parameter(Mandatory = $true)]$Session,
        [Parameter(Mandatory = $true)][int]$ExpectedCount,
        [int]$TimeoutSeconds = 30
    )
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $disks = @(Get-ResetSessionDisks -Session $Session)
        if ($disks.Count -ge $ExpectedCount) { return $disks }
        Start-Sleep -Seconds 1
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timed out waiting for $ExpectedCount iSCSI disks; observed $($disks.Count)"
}

function Write-ResetProgress {
    param(
        [string]$RequestId,
        [Parameter(Mandatory = $true)][string]$Event,
        [string]$Message = "",
        [hashtable]$Details = @{}
    )
    if (-not [string]::IsNullOrWhiteSpace($RequestId)) {
        Write-ResetLog -Level "INFO" -Event $Event -RequestId $RequestId `
            -Message $Message -Details $Details
    }
}

function Get-ResetExpectedLetter {
    param([Parameter(Mandatory = $true)]$Expected)
    $letter = ([string]$Expected.drive_letter).Trim().ToUpperInvariant()
    if ($letter -notmatch "^[A-Z]$") {
        throw "Invalid drive letter for volume $($Expected.name)"
    }
    return $letter
}

function Get-ResetDiskMappings {
    param([Parameter(Mandatory = $true)]$ExpectedVolumes, [Parameter(Mandatory = $true)]$Disks)
    if ($Disks.Count -ne $ExpectedVolumes.Count) {
        throw "Session exposed $($Disks.Count) disks; expected $($ExpectedVolumes.Count)"
    }

    $seenIds = @{}
    $seenLetters = @{}
    $mappings = @()
    foreach ($expected in $ExpectedVolumes) {
        $expectedId = Normalize-DiskId ([string]$expected.disk_unique_id)
        $desiredLetter = Get-ResetExpectedLetter -Expected $expected
        if ($seenIds.ContainsKey($expectedId)) { throw "Duplicate expected disk ID $expectedId" }
        if ($seenLetters.ContainsKey($desiredLetter)) {
            throw "Duplicate expected drive letter $desiredLetter`:"
        }
        $seenIds[$expectedId] = $true
        $seenLetters[$desiredLetter] = $true

        $matches = @($Disks | Where-Object {
            (Normalize-DiskId ([string]$_.UniqueId)) -eq $expectedId
        })
        if ($matches.Count -ne 1) {
            throw "Expected exactly one session disk for ID $expectedId"
        }
        if ($matches[0].IsReadOnly) {
            throw "Expected disk is unexpectedly read-only: $expectedId"
        }
        $mappings += [pscustomobject]@{
            Expected = $expected
            ExpectedId = $expectedId
            DesiredLetter = $desiredLetter
            Disk = $matches[0]
        }
    }
    return $mappings
}

function Get-ResetPartitionVolumes {
    param([Parameter(Mandatory = $true)]$Partition)
    return @($Partition | Get-Volume)
}

function Get-ResetDriveLetterVolumes {
    param([Parameter(Mandatory = $true)][char]$DriveLetter)
    return @(Get-Volume -DriveLetter $DriveLetter -ErrorAction SilentlyContinue)
}

function Get-ResetDriveLetterPartitions {
    param([Parameter(Mandatory = $true)][char]$DriveLetter)
    return @(Get-Partition -DriveLetter $DriveLetter -ErrorAction SilentlyContinue)
}

function Assert-ResetDesiredLettersPreflight {
    param([Parameter(Mandatory = $true)]$Mappings)
    $sessionDiskNumbers = @{}
    foreach ($mapping in $Mappings) {
        $sessionDiskNumbers[[int]$mapping.Disk.Number] = $true
    }

    foreach ($mapping in $Mappings) {
        $letter = [char]$mapping.DesiredLetter
        $volumes = @(Get-ResetDriveLetterVolumes -DriveLetter $letter)
        $partitions = @(Get-ResetDriveLetterPartitions -DriveLetter $letter)
        if ($volumes.Count -eq 0 -and $partitions.Count -eq 0) { continue }
        if ($volumes.Count -gt 1 -or $partitions.Count -ne 1) {
            throw "Drive letter $letter`: is occupied by an unverified device"
        }
        if (-not $sessionDiskNumbers.ContainsKey([int]$partitions[0].DiskNumber)) {
            throw "Drive letter $letter`: is occupied by a disk outside the client session"
        }
    }
}

function Wait-ResetVolumeAssignments {
    param(
        [Parameter(Mandatory = $true)]$Mappings,
        [int]$TimeoutSeconds = 30,
        [switch]$SkipOnline
    )
    if (-not $SkipOnline) {
        foreach ($mapping in $Mappings) {
            if ($mapping.Disk.IsOffline) {
                Set-Disk -Number $mapping.Disk.Number -IsOffline $false
            }
        }
    }

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $lastPending = "partition or volume metadata is not ready"
    do {
        $assignments = @()
        $pending = $false
        foreach ($mapping in $Mappings) {
            try {
                $partitions = @(Get-Partition -DiskNumber $mapping.Disk.Number | Where-Object {
                    $_.Type -notin @("Reserved", "System", "Recovery")
                })
            } catch {
                $partitions = @()
                $lastPending = $_.Exception.Message
            }
            if ($partitions.Count -gt 1) {
                throw "Disk $($mapping.ExpectedId) must have exactly one data partition"
            }
            if ($partitions.Count -eq 0) {
                $pending = $true
                continue
            }

            $partition = $partitions[0]
            try {
                $volumes = @(Get-ResetPartitionVolumes -Partition $partition)
            } catch {
                $volumes = @()
                $lastPending = $_.Exception.Message
            }
            if ($volumes.Count -gt 1) {
                throw "Partition for $($mapping.Expected.name) exposed more than one volume"
            }
            if ($volumes.Count -eq 0 -or
                [string]::IsNullOrWhiteSpace([string]$volumes[0].FileSystemLabel)) {
                $pending = $true
                continue
            }
            if ([string]$volumes[0].FileSystemLabel -ne [string]$mapping.Expected.label) {
                throw "Volume label mismatch for $($mapping.Expected.name)"
            }

            $assignments += [pscustomobject]@{
                Name = [string]$mapping.Expected.name
                ExpectedId = $mapping.ExpectedId
                DiskNumber = [int]$mapping.Disk.Number
                PartitionNumber = [int]$partition.PartitionNumber
                CurrentLetter = ([string]$partition.DriveLetter).ToUpperInvariant()
                DesiredLetter = $mapping.DesiredLetter
                ExpectedLabel = [string]$mapping.Expected.label
            }
        }
        if (-not $pending -and $assignments.Count -eq $Mappings.Count) {
            return $assignments
        }
        if ([DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Seconds 1
        }
    } while ([DateTime]::UtcNow -lt $deadline)

    throw "Timed out waiting for partition and volume metadata: $lastPending"
}

function Assert-ResetDriveLetterOwnership {
    param([Parameter(Mandatory = $true)]$Assignments)
    $sessionPartitions = @{}
    foreach ($assignment in $Assignments) {
        $key = "$($assignment.DiskNumber):$($assignment.PartitionNumber)"
        $sessionPartitions[$key] = $true
    }

    foreach ($assignment in $Assignments) {
        $letter = [char]$assignment.DesiredLetter
        $volumes = @(Get-ResetDriveLetterVolumes -DriveLetter $letter)
        $partitions = @(Get-ResetDriveLetterPartitions -DriveLetter $letter)
        if ($volumes.Count -eq 0 -and $partitions.Count -eq 0) { continue }
        if ($volumes.Count -ne 1 -or $partitions.Count -ne 1) {
            throw "Drive letter $letter`: is occupied by an unverified device"
        }
        $key = "$($partitions[0].DiskNumber):$($partitions[0].PartitionNumber)"
        if (-not $sessionPartitions.ContainsKey($key)) {
            throw "Drive letter $letter`: is occupied by a disk outside the client session"
        }
    }
}

function Set-ResetDriveLetters {
    param(
        [Parameter(Mandatory = $true)]$Mappings,
        [Parameter(Mandatory = $true)]$Assignments,
        [string]$RequestId = ""
    )
    Assert-ResetDriveLetterOwnership -Assignments $Assignments

    foreach ($assignment in $Assignments) {
        Write-ResetProgress -RequestId $RequestId -Event "disk_verified" `
            -Message "Client disk, partition, label, and requested letter verified" -Details @{
                disk_unique_id = $assignment.ExpectedId
                disk_number = $assignment.DiskNumber
                current_drive_letter = $assignment.CurrentLetter
                desired_drive_letter = $assignment.DesiredLetter
            }
    }

    # Remove only mismatched letters from the already-proven client partitions. This
    # breaks E<->F cycles before assigning the configured letters.
    foreach ($assignment in $Assignments) {
        if (-not [string]::IsNullOrWhiteSpace($assignment.CurrentLetter) -and
            $assignment.CurrentLetter -ne $assignment.DesiredLetter) {
            Remove-PartitionAccessPath -DiskNumber $assignment.DiskNumber `
                -PartitionNumber $assignment.PartitionNumber `
                -AccessPath "$($assignment.CurrentLetter):" -Confirm:$false
            Write-ResetProgress -RequestId $RequestId -Event "drive_letter_removed" `
                -Message "Removed an automatically assigned client drive letter" -Details @{
                    disk_unique_id = $assignment.ExpectedId
                    disk_number = $assignment.DiskNumber
                    current_drive_letter = $assignment.CurrentLetter
                    desired_drive_letter = $assignment.DesiredLetter
                }
        }
    }

    foreach ($assignment in $Assignments) {
        if ($assignment.CurrentLetter -ne $assignment.DesiredLetter) {
            Set-Partition -DiskNumber $assignment.DiskNumber `
                -PartitionNumber $assignment.PartitionNumber `
                -NewDriveLetter ([char]$assignment.DesiredLetter)
            Write-ResetProgress -RequestId $RequestId -Event "drive_letter_assigned" `
                -Message "Assigned the configured client drive letter" -Details @{
                    disk_unique_id = $assignment.ExpectedId
                    disk_number = $assignment.DiskNumber
                    current_drive_letter = $assignment.DesiredLetter
                    desired_drive_letter = $assignment.DesiredLetter
                }
        }
    }

    $verified = @(Wait-ResetVolumeAssignments -Mappings $Mappings -TimeoutSeconds 10 -SkipOnline)
    foreach ($assignment in $verified) {
        if ($assignment.CurrentLetter -ne $assignment.DesiredLetter) {
            throw "Drive letter verification failed for $($assignment.Name)"
        }
    }
}

function Mount-SimulationVolumes {
    param(
        [Parameter(Mandatory = $true)]$ExpectedVolumes,
        [Parameter(Mandatory = $true)]$Disks,
        [string]$RequestId = ""
    )
    if ($Disks.Count -ne $ExpectedVolumes.Count) {
        throw "Session exposed $($Disks.Count) disks; expected $($ExpectedVolumes.Count)"
    }
    $state = Read-SimulationState
    $sessionIds = @{}
    foreach ($disk in $Disks) {
        $sessionIds[(Normalize-DiskId ([string]$disk.unique_id))] = $true
    }

    $assignments = @()
    $seenIds = @{}
    $seenLetters = @{}
    foreach ($expected in $ExpectedVolumes) {
        $expectedId = Normalize-DiskId ([string]$expected.disk_unique_id)
        $desiredLetter = Get-ResetExpectedLetter -Expected $expected
        if ($seenIds.ContainsKey($expectedId)) { throw "Duplicate expected disk ID $expectedId" }
        if ($seenLetters.ContainsKey($desiredLetter)) {
            throw "Duplicate expected drive letter $desiredLetter`:"
        }
        $seenIds[$expectedId] = $true
        $seenLetters[$desiredLetter] = $true
        $matches = @($Disks | Where-Object {
            (Normalize-DiskId ([string]$_.unique_id)) -eq $expectedId
        })
        if ($matches.Count -ne 1) { throw "Expected exactly one disk for ID $expectedId" }
        $disk = $matches[0]
        if ($disk.is_read_only) { throw "Expected disk is read-only: $expectedId" }
        if ([string]$disk.label -ne [string]$expected.label) {
            throw "Volume label mismatch for $($expected.name)"
        }
        $occupied = @($state.disks | Where-Object {
            ([string]$_.drive_letter).ToUpperInvariant() -eq $desiredLetter -and
            -not $sessionIds.ContainsKey((Normalize-DiskId ([string]$_.unique_id)))
        })
        if ($occupied.Count -gt 0) {
            throw "Drive letter $desiredLetter`: is occupied by a disk outside the client session"
        }
        $assignments += [pscustomobject]@{
            Expected = $expected
            ExpectedId = $expectedId
            Disk = $disk
            CurrentLetter = ([string]$disk.drive_letter).ToUpperInvariant()
            DesiredLetter = $desiredLetter
        }
    }

    foreach ($assignment in $assignments) {
        Write-ResetProgress -RequestId $RequestId -Event "disk_verified" `
            -Message "Simulation client disk verified" -Details @{
                disk_unique_id = $assignment.ExpectedId
                current_drive_letter = $assignment.CurrentLetter
                desired_drive_letter = $assignment.DesiredLetter
            }
    }
    foreach ($assignment in $assignments) {
        foreach ($stateDisk in $state.disks) {
            if ((Normalize-DiskId ([string]$stateDisk.unique_id)) -eq $assignment.ExpectedId) {
                $stateDisk.is_offline = $false
                $stateDisk.drive_letter = $assignment.DesiredLetter
            }
        }
    }
    Save-SimulationState $state
}

function Mount-ResetVolumes {
    param(
        [Parameter(Mandatory = $true)]$ExpectedVolumes,
        [Parameter(Mandatory = $true)]$Disks,
        [string]$RequestId = ""
    )
    if (-not [string]::IsNullOrWhiteSpace($script:SimulationStatePath)) {
        Mount-SimulationVolumes -ExpectedVolumes $ExpectedVolumes -Disks $Disks `
            -RequestId $RequestId
        return
    }

    # Match the complete disk set before changing any disk state.
    $mappings = @(Get-ResetDiskMappings -ExpectedVolumes $ExpectedVolumes -Disks $Disks)
    Assert-ResetDesiredLettersPreflight -Mappings $mappings
    $assignments = @(Wait-ResetVolumeAssignments -Mappings $mappings -TimeoutSeconds 30)
    Set-ResetDriveLetters -Mappings $mappings -Assignments $assignments -RequestId $RequestId
}

function Write-EgsBytesAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][byte[]]$Bytes
    )
    $directory = Split-Path $Path -Parent
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $temporary = Join-Path $directory (".egs-write-" + [Guid]::NewGuid().ToString("N") + ".tmp")
    $backup = Join-Path $directory (".egs-write-" + [Guid]::NewGuid().ToString("N") + ".bak")
    try {
        [IO.File]::WriteAllBytes($temporary, $Bytes)
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

function Assert-ClientEgsItem {
    param(
        [Parameter(Mandatory = $true)]$Item,
        [Parameter(Mandatory = $true)]$Entry,
        [Parameter(Mandatory = $true)][string]$VolumeRoot
    )
    $appName = Get-RequiredEgsString -Item $Item -Name "AppName"
    $guid = Get-RequiredEgsString -Item $Item -Name "InstallationGuid"
    if (-not (Test-EgsInstallationId $guid)) {
        throw "$appName has an invalid Epic installation identifier"
    }
    if ($appName -ne [string]$Entry.app_name -or
        $guid -ne [string]$Entry.installation_guid) {
        throw "Epic Games bundle entry identity does not match its payload"
    }
    Get-RequiredEgsString -Item $Item -Name "AppVersionString" | Out-Null
    if ($Item.PSObject.Properties.Name -notcontains "InstallTags") {
        throw "$appName manifest has no InstallTags"
    }

    $installLocation = ConvertTo-EgsCanonicalPath (
        Get-RequiredEgsString -Item $Item -Name "InstallLocation"
    )
    if (-not (Test-EgsPathWithinRoot -Path $installLocation -RootPath $VolumeRoot)) {
        throw "$appName install path does not belong to its client volume"
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
    return [pscustomobject]@{
        AppName = $appName
        InstallationGuid = $guid
        InstallLocation = $installLocation
    }
}

function Read-ClientEgsBundle {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ConfigRevision,
        [Parameter(Mandatory = $true)][string]$VolumeName,
        [Parameter(Mandatory = $true)][string]$VolumeRoot
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Epic Games bundle is missing for volume $VolumeName"
    }
    $bundle = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ([int]$bundle.schema_version -ne 1 -or
        [string]$bundle.config_revision -ne $ConfigRevision -or
        [string]$bundle.volume_name -ne $VolumeName -or
        $bundle.PSObject.Properties.Name -notcontains "manifests") {
        throw "Epic Games bundle does not match volume $VolumeName and current config revision"
    }

    $result = @()
    foreach ($entry in @($bundle.manifests)) {
        try {
            $bytes = [Convert]::FromBase64String([string]$entry.payload_base64)
        } catch {
            throw "Epic Games bundle payload is not valid Base64 for $($entry.app_name)"
        }
        $sha = Get-EgsSha256Hex $bytes
        if ($sha -ne ([string]$entry.sha256).ToLowerInvariant()) {
            throw "Epic Games bundle hash verification failed for $($entry.app_name)"
        }
        try {
            $item = ConvertFrom-EgsJsonBytes -Bytes $bytes
        } catch {
            throw "Epic Games bundle payload is not valid JSON for $($entry.app_name)"
        }
        $identity = Assert-ClientEgsItem -Item $item -Entry $entry -VolumeRoot $VolumeRoot
        $result += [pscustomobject]@{
            AppName = $identity.AppName
            InstallationGuid = $identity.InstallationGuid
            InstallLocation = $identity.InstallLocation
            Sha256 = $sha
            Bytes = $bytes
            TargetFileName = "$($identity.InstallationGuid).item"
        }
    }
    return $result
}

function Read-ExistingEgsManifests {
    param([Parameter(Mandatory = $true)][string]$ManifestDirectory)
    if (-not (Test-Path -LiteralPath $ManifestDirectory -PathType Container)) { return @() }
    $result = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $ManifestDirectory -Filter "*.item" -File)) {
        $bytes = [IO.File]::ReadAllBytes($file.FullName)
        try {
            $item = ConvertFrom-EgsJsonBytes -Bytes $bytes
        } catch {
            throw "Existing Epic Games manifest is not valid JSON: $($file.FullName)"
        }
        $result += [pscustomobject]@{
            AppName = Get-RequiredEgsString -Item $item -Name "AppName"
            InstallationGuid = Get-RequiredEgsString -Item $item -Name "InstallationGuid"
            InstallLocation = ConvertTo-EgsCanonicalPath (
                Get-RequiredEgsString -Item $item -Name "InstallLocation"
            )
            Sha256 = Get-EgsSha256Hex $bytes
            FileName = $file.Name
        }
    }
    return $result
}

function Read-ClientEgsManagedState {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ schema_version = 1; manifests = @() }
    }
    $state = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ([int]$state.schema_version -ne 1 -or
        $state.PSObject.Properties.Name -notcontains "manifests") {
        throw "Epic Games managed state is invalid: $Path"
    }
    $seen = @{}
    foreach ($entry in @($state.manifests)) {
        $appName = [string]$entry.app_name
        $guid = [string]$entry.installation_guid
        $sha256 = [string]$entry.sha256
        if ([string]::IsNullOrWhiteSpace($appName) -or $seen.ContainsKey($appName) -or
            -not (Test-EgsInstallationId $guid) -or $sha256 -notmatch "^[0-9A-Fa-f]{64}$") {
            throw "Epic Games managed state contains an invalid or duplicate AppName"
        }
        $seen[$appName] = $true
        ConvertTo-EgsCanonicalPath ([string]$entry.install_location) | Out-Null
    }
    return $state
}

function New-ClientEgsSyncPlan {
    param(
        [Parameter(Mandatory = $true)]$Desired,
        [Parameter(Mandatory = $true)]$Existing,
        [Parameter(Mandatory = $true)]$ManagedState
    )
    $desiredByApp = @{}
    $desiredFiles = @{}
    foreach ($entry in $Desired) {
        if ($desiredByApp.ContainsKey($entry.AppName)) {
            throw "Duplicate Epic Games AppName across client volumes: $($entry.AppName)"
        }
        if ($desiredFiles.ContainsKey($entry.TargetFileName)) {
            throw "Duplicate Epic Games InstallationGuid across client volumes"
        }
        $desiredByApp[$entry.AppName] = $entry
        $desiredFiles[$entry.TargetFileName] = $true
    }
    $managedByApp = @{}
    foreach ($entry in @($ManagedState.manifests)) {
        $managedByApp[[string]$entry.app_name] = $entry
    }

    $affected = @{}
    $remove = @{}
    foreach ($desiredEntry in $Desired) {
        $sameName = @($Existing | Where-Object { $_.AppName -eq $desiredEntry.AppName })
        $sameTarget = @($Existing | Where-Object {
            $_.FileName -eq $desiredEntry.TargetFileName
        })
        foreach ($entry in $sameTarget) {
            if ($entry.AppName -ne $desiredEntry.AppName) {
                throw "Epic target .item filename belongs to another local application"
            }
        }
        if (-not $managedByApp.ContainsKey($desiredEntry.AppName)) {
            if ($sameName.Count -gt 0 -or $sameTarget.Count -gt 0) {
                throw "Local Epic installation is not managed by iSCSI reset: $($desiredEntry.AppName)"
            }
        } else {
            $managedEntry = $managedByApp[$desiredEntry.AppName]
            $managedFileName = "$([string]$managedEntry.installation_guid).item"
            $managedExisting = @($Existing | Where-Object { $_.FileName -eq $managedFileName })
            if ($managedExisting.Count -gt 1) {
                throw "Previously managed Epic manifest is ambiguous: $($desiredEntry.AppName)"
            }
            if ($managedExisting.Count -eq 1) {
                $managedLocation = ConvertTo-EgsCanonicalPath (
                    [string]$managedEntry.install_location
                )
                if ($managedExisting[0].AppName -ne $desiredEntry.AppName -or
                    $managedExisting[0].InstallationGuid -ne
                        [string]$managedEntry.installation_guid -or
                    -not $managedExisting[0].InstallLocation.Equals(
                        $managedLocation, [StringComparison]::OrdinalIgnoreCase
                    )) {
                    throw "Previously managed Epic manifest identity changed: $($desiredEntry.AppName)"
                }
                $affected[$managedFileName] = $true
                if ($managedFileName -ne $desiredEntry.TargetFileName) {
                    $remove[$managedFileName] = $true
                }
            }
            $unexpectedSameName = @($sameName | Where-Object {
                $_.FileName -ne $managedFileName
            })
            if ($unexpectedSameName.Count -gt 0 -or
                ($sameTarget.Count -gt 0 -and $managedFileName -ne $desiredEntry.TargetFileName)) {
                throw "Local Epic installation conflicts with managed AppName: $($desiredEntry.AppName)"
            }
        }
        $affected[$desiredEntry.TargetFileName] = $true
    }

    foreach ($appName in @($managedByApp.Keys)) {
        if ($desiredByApp.ContainsKey($appName)) { continue }
        $managedEntry = $managedByApp[$appName]
        $managedFileName = "$([string]$managedEntry.installation_guid).item"
        $managedExisting = @($Existing | Where-Object { $_.FileName -eq $managedFileName })
        if ($managedExisting.Count -gt 1) {
            throw "Previously managed Epic manifest is ambiguous: $appName"
        }
        foreach ($entry in $managedExisting) {
            $managedLocation = ConvertTo-EgsCanonicalPath ([string]$managedEntry.install_location)
            if ($entry.AppName -ne $appName -or
                $entry.InstallationGuid -ne [string]$managedEntry.installation_guid -or
                -not $entry.InstallLocation.Equals(
                    $managedLocation, [StringComparison]::OrdinalIgnoreCase
                )) {
                throw "Previously managed Epic manifest identity changed: $appName"
            }
            $affected[$managedFileName] = $true
            $remove[$managedFileName] = $true
        }
    }

    return [pscustomobject]@{
        Desired = @($Desired | Sort-Object AppName)
        PreviouslyManagedAppNames = @($managedByApp.Keys)
        AffectedFileNames = @($affected.Keys | Sort-Object)
        RemoveFileNames = @($remove.Keys | Sort-Object)
    }
}

function Start-ClientEgsTransaction {
    param(
        [Parameter(Mandatory = $true)][string]$ManifestDirectory,
        [Parameter(Mandatory = $true)][string]$StatePath,
        [Parameter(Mandatory = $true)][string]$TransactionPath,
        [Parameter(Mandatory = $true)]$AffectedFileNames
    )
    if (Test-Path -LiteralPath $TransactionPath) {
        throw "An unrecovered Epic Games manifest transaction already exists"
    }
    try {
        $backupDirectory = Join-Path $TransactionPath "backup"
        New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
        if (-not (Test-Path -LiteralPath $ManifestDirectory)) {
            New-Item -ItemType Directory -Path $ManifestDirectory -Force | Out-Null
        }

        $files = @()
        $index = 0
        foreach ($fileName in $AffectedFileNames) {
            if ([IO.Path]::GetFileName($fileName) -ne $fileName -or $fileName -notlike "*.item") {
                throw "Unsafe Epic Games manifest transaction filename: $fileName"
            }
            $target = Join-Path $ManifestDirectory $fileName
            $exists = Test-Path -LiteralPath $target -PathType Leaf
            $backupName = "$index.bak"
            $sha = ""
            if ($exists) {
                $bytes = [IO.File]::ReadAllBytes($target)
                $sha = Get-EgsSha256Hex $bytes
                [IO.File]::WriteAllBytes((Join-Path $backupDirectory $backupName), $bytes)
            }
            $files += [ordered]@{
                file_name = $fileName
                existed = $exists
                sha256 = $sha
                backup_name = $backupName
            }
            $index++
        }

        $stateExists = Test-Path -LiteralPath $StatePath -PathType Leaf
        $stateSha = ""
        if ($stateExists) {
            $stateBytes = [IO.File]::ReadAllBytes($StatePath)
            $stateSha = Get-EgsSha256Hex $stateBytes
            [IO.File]::WriteAllBytes((Join-Path $backupDirectory "state.bak"), $stateBytes)
        }
        $journal = [ordered]@{
            schema_version = 1
            manifest_directory = $ManifestDirectory
            state_path = $StatePath
            files = $files
            state_existed = $stateExists
            state_sha256 = $stateSha
        }
        $journalPath = Join-Path $TransactionPath "journal.json"
        [IO.File]::WriteAllText(
            $journalPath,
            ($journal | ConvertTo-Json -Depth 6),
            (New-Object Text.UTF8Encoding($false))
        )
    } catch {
        Remove-Item -LiteralPath $TransactionPath -Recurse -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Restore-ClientEgsTransaction {
    param([Parameter(Mandatory = $true)][string]$TransactionPath)
    Assert-EgsLauncherStopped
    $journalPath = Join-Path $TransactionPath "journal.json"
    if (-not (Test-Path -LiteralPath $journalPath -PathType Leaf)) {
        throw "Epic Games manifest transaction journal is missing"
    }
    $journal = Get-Content -LiteralPath $journalPath -Raw | ConvertFrom-Json
    if ([int]$journal.schema_version -ne 1) {
        throw "Epic Games manifest transaction journal version is unsupported"
    }
    $manifestDirectory = [string]$journal.manifest_directory
    $statePath = [string]$journal.state_path
    $backupDirectory = Join-Path $TransactionPath "backup"
    $errors = @()

    foreach ($entry in @($journal.files)) {
        try {
            $fileName = [string]$entry.file_name
            if ([IO.Path]::GetFileName($fileName) -ne $fileName -or $fileName -notlike "*.item") {
                throw "Unsafe transaction filename"
            }
            $target = Join-Path $manifestDirectory $fileName
            if ([bool]$entry.existed) {
                $backup = Join-Path $backupDirectory ([string]$entry.backup_name)
                $bytes = [IO.File]::ReadAllBytes($backup)
                if ((Get-EgsSha256Hex $bytes) -ne [string]$entry.sha256) {
                    throw "Backup hash mismatch"
                }
                Write-EgsBytesAtomic -Path $target -Bytes $bytes
                if ((Get-EgsSha256Hex ([IO.File]::ReadAllBytes($target))) -ne
                    [string]$entry.sha256) {
                    throw "Restored manifest hash mismatch"
                }
            } elseif (Test-Path -LiteralPath $target) {
                Remove-Item -LiteralPath $target -Force
            }
        } catch {
            $errors += "$($entry.file_name): $($_.Exception.Message)"
        }
    }

    try {
        if ([bool]$journal.state_existed) {
            $bytes = [IO.File]::ReadAllBytes((Join-Path $backupDirectory "state.bak"))
            if ((Get-EgsSha256Hex $bytes) -ne [string]$journal.state_sha256) {
                throw "Managed state backup hash mismatch"
            }
            Write-EgsBytesAtomic -Path $statePath -Bytes $bytes
        } elseif (Test-Path -LiteralPath $statePath) {
            Remove-Item -LiteralPath $statePath -Force
        }
    } catch {
        $errors += "managed state: $($_.Exception.Message)"
    }
    if ($errors.Count -gt 0) {
        throw ("Epic Games manifest rollback is incomplete: " + ($errors -join "; "))
    }
    Assert-EgsLauncherStopped
    Remove-Item -LiteralPath $TransactionPath -Recurse -Force
}

function Write-ClientEgsManagedState {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Desired
    )
    $state = [ordered]@{
        schema_version = 1
        manifests = @($Desired | Sort-Object AppName | ForEach-Object {
            [ordered]@{
                app_name = $_.AppName
                installation_guid = $_.InstallationGuid
                install_location = $_.InstallLocation
                sha256 = $_.Sha256
            }
        })
    }
    $json = $state | ConvertTo-Json -Depth 5
    Write-EgsBytesAtomic -Path $Path -Bytes ([Text.Encoding]::UTF8.GetBytes($json))
}

function Assert-ClientEgsSyncResult {
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [Parameter(Mandatory = $true)][string]$ManifestDirectory,
        [Parameter(Mandatory = $true)][string]$StatePath
    )
    $current = @(Read-ExistingEgsManifests -ManifestDirectory $ManifestDirectory)
    foreach ($desired in $Plan.Desired) {
        $matches = @($current | Where-Object { $_.AppName -eq $desired.AppName })
        if ($matches.Count -ne 1 -or
            $matches[0].FileName -ne $desired.TargetFileName -or
            $matches[0].Sha256 -ne $desired.Sha256) {
            throw "Epic Games manifest commit verification failed for $($desired.AppName)"
        }
    }
    $desiredNames = @{}
    foreach ($desired in $Plan.Desired) { $desiredNames[$desired.AppName] = $true }
    foreach ($appName in $Plan.PreviouslyManagedAppNames) {
        if (-not $desiredNames.ContainsKey($appName) -and
            @($current | Where-Object { $_.AppName -eq $appName }).Count -ne 0) {
            throw "Stale managed Epic Games manifest still exists: $appName"
        }
    }
    $state = Read-ClientEgsManagedState -Path $StatePath
    if (@($state.manifests).Count -ne @($Plan.Desired).Count) {
        throw "Epic Games managed state count does not match committed manifests"
    }
    foreach ($desired in $Plan.Desired) {
        $stateMatches = @($state.manifests | Where-Object {
            [string]$_.app_name -eq $desired.AppName
        })
        if ($stateMatches.Count -ne 1 -or
            [string]$stateMatches[0].installation_guid -ne $desired.InstallationGuid -or
            [string]$stateMatches[0].sha256 -ne $desired.Sha256 -or
            -not (ConvertTo-EgsCanonicalPath (
                [string]$stateMatches[0].install_location
            )).Equals($desired.InstallLocation, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Epic Games managed state verification failed for $($desired.AppName)"
        }
    }
}

function Invoke-ClientEgsTransaction {
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [Parameter(Mandatory = $true)][string]$ManifestDirectory,
        [Parameter(Mandatory = $true)][string]$StatePath,
        [Parameter(Mandatory = $true)][string]$TransactionPath
    )
    Start-ClientEgsTransaction -ManifestDirectory $ManifestDirectory -StatePath $StatePath `
        -TransactionPath $TransactionPath -AffectedFileNames $Plan.AffectedFileNames
    try {
        Assert-EgsLauncherStopped
        foreach ($desired in $Plan.Desired) {
            Write-EgsBytesAtomic -Path (Join-Path $ManifestDirectory $desired.TargetFileName) `
                -Bytes $desired.Bytes
        }
        foreach ($fileName in $Plan.RemoveFileNames) {
            $path = Join-Path $ManifestDirectory $fileName
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
        }
        Write-ClientEgsManagedState -Path $StatePath -Desired $Plan.Desired
        Assert-EgsLauncherStopped
        Assert-ClientEgsSyncResult -Plan $Plan -ManifestDirectory $ManifestDirectory `
            -StatePath $StatePath
        Assert-EgsLauncherStopped
        Remove-Item -LiteralPath $TransactionPath -Recurse -Force
    } catch {
        $failure = $_
        try { Stop-EgsLauncherProcesses } catch { }
        try {
            Restore-ClientEgsTransaction -TransactionPath $TransactionPath
        } catch {
            throw "Epic Games manifest sync failed and rollback did not complete: $($_.Exception.Message)"
        }
        throw $failure
    }
}

function Invoke-ClientEgsManifestSync {
    param(
        [Parameter(Mandatory = $true)]$ExpectedVolumes,
        [Parameter(Mandatory = $true)][string]$ConfigRevision,
        [Parameter(Mandatory = $true)][string]$SyncConfigPath,
        [string]$ManifestDirectory = "C:\ProgramData\Epic\EpicGamesLauncher\Data\Manifests"
    )
    Stop-EgsLauncherProcesses
    $installRoot = Split-Path $SyncConfigPath -Parent
    $statePath = Join-Path $installRoot "egs-managed-apps.v1.json"
    $transactionPath = Join-Path $installRoot "egs-sync-transaction"
    if (Test-Path -LiteralPath $transactionPath) {
        Restore-ClientEgsTransaction -TransactionPath $transactionPath
    }

    $desired = @()
    foreach ($volume in $ExpectedVolumes) {
        $letter = ([string]$volume.drive_letter).Trim().ToUpperInvariant()
        if ($letter -notmatch "^[A-Z]$") {
            throw "Invalid drive letter for Epic Games volume $($volume.name)"
        }
        $root = "$letter`:\"
        $bundlePath = Join-Path $root ".iscsi-reset\egs-manifests.v1.json"
        $desired += @(Read-ClientEgsBundle -Path $bundlePath `
            -ConfigRevision $ConfigRevision -VolumeName ([string]$volume.name) -VolumeRoot $root)
    }
    $existing = @(Read-ExistingEgsManifests -ManifestDirectory $ManifestDirectory)
    $managed = Read-ClientEgsManagedState -Path $statePath
    $plan = New-ClientEgsSyncPlan -Desired $desired -Existing $existing -ManagedState $managed
    Invoke-ClientEgsTransaction -Plan $plan -ManifestDirectory $ManifestDirectory `
        -StatePath $statePath -TransactionPath $transactionPath
    return @($desired).Count
}

function Invoke-ResetMain {
    param(
        [string]$BaseUrl,
        [string]$ClientTokenPath,
        [string]$SyncConfigPath = "",
        [int]$TimeoutSeconds
    )
    $SyncConfigPath = Resolve-EgsSyncConfigPath -Path $SyncConfigPath
    $requestId = [Guid]::NewGuid().ToString("D")
    $connectedTarget = ""
    $stage = "startup"
    try {
        Write-ResetProgress -RequestId $requestId -Event "start" `
            -Message "Client reset task started"
        if (-not (Test-Path -LiteralPath $ClientTokenPath)) { throw "Token file not found" }
        $token = (Get-Content -LiteralPath $ClientTokenPath -Raw).Trim()
        if ([string]::IsNullOrWhiteSpace($token)) { throw "Token file is empty" }
        if ($BaseUrl.StartsWith("http://") -and
            ([string]::IsNullOrWhiteSpace($script:SimulationStatePath) -or -not $script:AllowHttpForSimulation)) {
            throw "Plain HTTP is permitted only in explicit simulation mode"
        }
        if ([string]::IsNullOrWhiteSpace($script:SimulationStatePath)) {
            Set-Service -Name MSiSCSI -StartupType Automatic
            Start-Service -Name MSiSCSI
        }
        $egsSyncEnabled = Get-EgsManifestSyncEnabled -Path $SyncConfigPath
        $health = Wait-ResetApi -BaseUrl $BaseUrl -RequestId $requestId `
            -TimeoutSeconds $TimeoutSeconds
        Write-ResetProgress -RequestId $requestId -Event "api_ready" `
            -Message "Reset API is reachable"
        $stage = "client_configuration"
        $client = Invoke-ResetRequest -Method GET -Uri "$BaseUrl/v1/client" -Token $token -RequestId $requestId
        Write-ResetProgress -RequestId $requestId -Event "client_configuration_loaded" `
            -Message "Client target configuration loaded" -Details @{
                target_iqn = [string]$client.target_iqn
            }
        if (@(Get-ResetSessions -TargetIqn ([string]$client.target_iqn)).Count -gt 0) {
            throw (New-ApiException -StatusCode 409 -Code "LOCAL_SESSION_ACTIVE" -Message "Target is already connected locally")
        }
        $stage = "prepare"
        $prepared = Invoke-PrepareWithRetry -BaseUrl $BaseUrl -Token $token -RequestId $requestId -TimeoutSeconds $TimeoutSeconds
        Write-ResetProgress -RequestId $requestId -Event "prepared" `
            -Message "Server prepared the complete client volume set" -Details @{
                target_iqn = [string]$prepared.target_iqn
                volume_count = @($prepared.volumes).Count
            }
        $stage = "connect"
        Ensure-ResetPortal -Portal $prepared.portal
        Wait-ResetTargetDiscovery -TargetIqn ([string]$prepared.target_iqn) `
            -Portal $prepared.portal -RequestId $requestId | Out-Null
        $session = Connect-ResetTarget -TargetIqn ([string]$prepared.target_iqn) -Portal $prepared.portal
        $connectedTarget = [string]$prepared.target_iqn
        Write-ResetProgress -RequestId $requestId -Event "target_connected" `
            -Message "Created a non-persistent iSCSI session" -Details @{
                target_iqn = $connectedTarget
            }
        $stage = "disk_validation"
        $disks = @(Wait-ResetSessionDisks -Session $session -ExpectedCount @($prepared.volumes).Count)
        Mount-ResetVolumes -ExpectedVolumes @($prepared.volumes) -Disks $disks `
            -RequestId $requestId
        if ($egsSyncEnabled) {
            $stage = "egs_manifest_sync"
            $manifestCount = Invoke-ClientEgsManifestSync `
                -ExpectedVolumes @($prepared.volumes) `
                -ConfigRevision ([string]$health.config_revision) `
                -SyncConfigPath $SyncConfigPath
            Write-ResetProgress -RequestId $requestId -Event "egs_manifest_sync_ready" `
                -Message "Epic Games manifests match the mounted release" -Details @{
                    manifest_count = $manifestCount
                }
        }
        Write-ResetLog -Level "INFO" -Event "ready" -RequestId $requestId `
            -Message "Target connected and verified" -Details @{
                target_iqn = $connectedTarget
                volume_count = @($prepared.volumes).Count
            }
        return 0
    } catch {
        $failure = $_
        if (-not [string]::IsNullOrWhiteSpace($connectedTarget)) {
            $disconnectVerified = $false
            try {
                Disconnect-ResetTarget -TargetIqn $connectedTarget
                $disconnectVerified = @(
                    Get-ResetSessions -TargetIqn $connectedTarget
                ).Count -eq 0
            } catch { }
            if ($disconnectVerified) {
                Write-ResetProgress -RequestId $requestId `
                    -Event "target_disconnected_after_error" `
                    -Message "Disconnected the session created by this run" -Details @{
                        target_iqn = $connectedTarget
                        stage = $stage
                    }
            } else {
                Write-ResetLog -Level "ERROR" -Event "target_disconnect_failed" `
                    -RequestId $requestId `
                    -Message "Could not verify removal of the session created by this run" `
                    -Details @{ target_iqn = $connectedTarget; stage = $stage }
            }
        }
        $code = "CLIENT_ERROR"
        if ($failure.Exception.Data.Contains("Code")) {
            $code = [string]$failure.Exception.Data["Code"]
        }
        Write-ResetLog -Level "ERROR" -Event $code -RequestId $requestId `
            -Message "$stage`: $($failure.Exception.Message)" -Details @{ stage = $stage }
        if ($stage -in @("disk_validation", "connect", "egs_manifest_sync")) { return 40 }
        if ($stage -eq "prepare" -or $stage -eq "client_configuration") { return 20 }
        return 10
    }
}

if (-not $NoMain) {
    $exitCode = Invoke-ResetMain -BaseUrl $ApiBaseUrl -ClientTokenPath $TokenPath `
        -SyncConfigPath $EgsSyncConfigPath -TimeoutSeconds $WaitTimeoutSeconds
    if ($PassThruExitCode) {
        Write-Output $exitCode
    } else {
        exit $exitCode
    }
}
