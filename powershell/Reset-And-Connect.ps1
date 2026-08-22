[CmdletBinding()]
param(
    [string]$ApiBaseUrl = "https://10.20.40.10:8443",
    [string]$TokenPath = "C:\ProgramData\IscsiReset\client.token",
    [int]$WaitTimeoutSeconds = 120,
    [string]$SimulationStatePath = "",
    [string]$SimulationSourceIp = "",
    [switch]$AllowHttpForSimulation,
    [switch]$PassThruExitCode,
    [switch]$NoMain
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

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
            Invoke-ResetRequest -Method GET -Uri "$BaseUrl/healthz" -RequestId $RequestId -TimeoutSec 5 | Out-Null
            return
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
    Update-IscsiTarget -NodeAddress $TargetIqn -ErrorAction SilentlyContinue | Out-Null
    $target = Get-IscsiTarget -NodeAddress $TargetIqn
    if ($null -eq $target) { throw "iSCSI target was not discovered: $TargetIqn" }
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

function Invoke-ResetMain {
    param(
        [string]$BaseUrl,
        [string]$ClientTokenPath,
        [int]$TimeoutSeconds
    )
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
        Wait-ResetApi -BaseUrl $BaseUrl -RequestId $requestId -TimeoutSeconds $TimeoutSeconds
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
        if ($stage -eq "disk_validation" -or $stage -eq "connect") { return 40 }
        if ($stage -eq "prepare" -or $stage -eq "client_configuration") { return 20 }
        return 10
    }
}

if (-not $NoMain) {
    $exitCode = Invoke-ResetMain -BaseUrl $ApiBaseUrl -ClientTokenPath $TokenPath -TimeoutSeconds $WaitTimeoutSeconds
    if ($PassThruExitCode) {
        Write-Output $exitCode
    } else {
        exit $exitCode
    }
}
