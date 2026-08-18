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
        [string]$LogPath = ""
    )
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
    [ordered]@{
        timestamp = [DateTime]::UtcNow.ToString("o")
        level = $Level
        event = $Event
        request_id = $RequestId
        message = $Message
    } | ConvertTo-Json -Compress | Add-Content -LiteralPath $LogPath -Encoding UTF8
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

function Mount-SimulationVolumes {
    param([Parameter(Mandatory = $true)]$ExpectedVolumes, [Parameter(Mandatory = $true)]$Disks)
    $state = Read-SimulationState
    foreach ($expected in $ExpectedVolumes) {
        $expectedId = Normalize-DiskId ([string]$expected.disk_unique_id)
        $matches = @($Disks | Where-Object { (Normalize-DiskId ([string]$_.unique_id)) -eq $expectedId })
        if ($matches.Count -ne 1) { throw "Expected exactly one disk for ID $expectedId" }
        $disk = $matches[0]
        if ([string]$disk.label -ne [string]$expected.label) {
            throw "Volume label mismatch for $($expected.name)"
        }
        $occupied = @($state.disks | Where-Object {
            $_.drive_letter -eq [string]$expected.drive_letter -and
            (Normalize-DiskId ([string]$_.unique_id)) -ne $expectedId
        })
        if ($occupied.Count -gt 0) { throw "Drive letter $($expected.drive_letter): is occupied" }
        foreach ($stateDisk in $state.disks) {
            if ((Normalize-DiskId ([string]$stateDisk.unique_id)) -eq $expectedId) {
                if ($stateDisk.is_read_only) { throw "Expected disk is read-only: $expectedId" }
                $stateDisk.is_offline = $false
                $stateDisk.drive_letter = [string]$expected.drive_letter
            }
        }
    }
    Save-SimulationState $state
}

function Mount-ResetVolumes {
    param([Parameter(Mandatory = $true)]$ExpectedVolumes, [Parameter(Mandatory = $true)]$Disks)
    if ($Disks.Count -ne $ExpectedVolumes.Count) {
        throw "Session exposed $($Disks.Count) disks; expected $($ExpectedVolumes.Count)"
    }
    if (-not [string]::IsNullOrWhiteSpace($script:SimulationStatePath)) {
        Mount-SimulationVolumes -ExpectedVolumes $ExpectedVolumes -Disks $Disks
        return
    }
    # Match the complete disk set before changing any disk state.
    $matched = @()
    foreach ($expected in $ExpectedVolumes) {
        $expectedId = Normalize-DiskId ([string]$expected.disk_unique_id)
        $matches = @($Disks | Where-Object { (Normalize-DiskId ([string]$_.UniqueId)) -eq $expectedId })
        if ($matches.Count -ne 1) { throw "Expected exactly one session disk for ID $expectedId" }

        $matched += [pscustomobject]@{
            Expected = $expected
            Disk = $matches[0]
        }
    }

    # Bring online only the proven session disks. Drive letters are assigned
    # only after every partition, label and letter check has succeeded.
    $assignments = @()
    foreach ($entry in $matched) {
        $expected = $entry.Expected
        $expectedId = Normalize-DiskId ([string]$expected.disk_unique_id)
        $disk = $entry.Disk
        if ($disk.IsReadOnly) { throw "Expected disk is unexpectedly read-only: $expectedId" }
        if ($disk.IsOffline) { Set-Disk -Number $disk.Number -IsOffline $false }
        $partitions = @(Get-Partition -DiskNumber $disk.Number | Where-Object {
            $_.Type -notin @("Reserved", "System", "Recovery")
        })
        if ($partitions.Count -ne 1) { throw "Disk $expectedId must have exactly one data partition" }
        $partition = $partitions[0]
        $volume = $partition | Get-Volume
        if ($null -eq $volume -or [string]$volume.FileSystemLabel -ne [string]$expected.label) {
            throw "Volume label mismatch for $($expected.name)"
        }
        $desiredLetter = [char]([string]$expected.drive_letter)
        $occupied = Get-Volume -DriveLetter $desiredLetter -ErrorAction SilentlyContinue
        if ($null -ne $occupied -and $partition.DriveLetter -ne $desiredLetter) {
            throw "Drive letter $desiredLetter`: is occupied"
        }

        $assignments += [pscustomobject]@{
            DiskNumber = $disk.Number
            PartitionNumber = $partition.PartitionNumber
            CurrentLetter = [string]$partition.DriveLetter
            DesiredLetter = $desiredLetter
        }
    }

    foreach ($assignment in $assignments) {
        if ($assignment.CurrentLetter -ne [string]$assignment.DesiredLetter) {
            Set-Partition `
                -DiskNumber $assignment.DiskNumber `
                -PartitionNumber $assignment.PartitionNumber `
                -NewDriveLetter $assignment.DesiredLetter
        }
    }
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
        $stage = "client_configuration"
        $client = Invoke-ResetRequest -Method GET -Uri "$BaseUrl/v1/client" -Token $token -RequestId $requestId
        if (@(Get-ResetSessions -TargetIqn ([string]$client.target_iqn)).Count -gt 0) {
            throw (New-ApiException -StatusCode 409 -Code "LOCAL_SESSION_ACTIVE" -Message "Target is already connected locally")
        }
        $stage = "prepare"
        $prepared = Invoke-PrepareWithRetry -BaseUrl $BaseUrl -Token $token -RequestId $requestId -TimeoutSeconds $TimeoutSeconds
        $stage = "connect"
        Ensure-ResetPortal -Portal $prepared.portal
        $session = Connect-ResetTarget -TargetIqn ([string]$prepared.target_iqn) -Portal $prepared.portal
        $connectedTarget = [string]$prepared.target_iqn
        $stage = "disk_validation"
        $disks = @(Wait-ResetSessionDisks -Session $session -ExpectedCount @($prepared.volumes).Count)
        Mount-ResetVolumes -ExpectedVolumes @($prepared.volumes) -Disks $disks
        Write-ResetLog -Level "INFO" -Event "ready" -RequestId $requestId -Message "Target connected and verified"
        return 0
    } catch {
        if (-not [string]::IsNullOrWhiteSpace($connectedTarget)) {
            try { Disconnect-ResetTarget -TargetIqn $connectedTarget } catch { }
        }
        $code = "CLIENT_ERROR"
        if ($_.Exception.Data.Contains("Code")) { $code = [string]$_.Exception.Data["Code"] }
        Write-ResetLog -Level "ERROR" -Event $code -RequestId $requestId -Message "$stage`: $($_.Exception.Message)"
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
