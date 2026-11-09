#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet("Watch", "SessionStarted", "ResetStarting", "Arm")][string]$Mode = "Watch",
    [string]$InstallRoot = "C:\ProgramData\IscsiReset",
    $Snapshot,
    [string]$SimulationPath = "",
    [switch]$NoMain
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
$script:WatchRoot = $InstallRoot
$script:WatchSimulationPath = $SimulationPath
$script:WatchTaskPath = "\IscsiReset\"
$script:WatchTaskName = "Disk Watcher"
$script:WatchBootCached = $null

function Get-WatchPath {
    param([string]$Name)
    return Join-Path $script:WatchRoot $Name
}

function Read-WatchJson {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Watcher file missing" }
    if (((Get-Item -LiteralPath $Path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Watcher files must not be reparse points"
    }
    return Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
}

function Write-WatchJson {
    param([string]$Path, [Parameter(Mandatory = $true)]$Value)
    $temporary = $Path + "." + [Guid]::NewGuid().ToString("N") + ".tmp"
    try {
        $json = $Value | ConvertTo-Json -Depth 12 -Compress
        [IO.File]::WriteAllText($temporary, $json, (New-Object Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $Path) {
            if (((Get-Item -LiteralPath $Path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Watcher files must not be reparse points"
            }
            [IO.File]::Replace($temporary, $Path, [NullString]::Value)
        } else { [IO.File]::Move($temporary, $Path) }
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Read-WatchSimulation {
    return Read-WatchJson -Path $script:WatchSimulationPath
}

function Get-WatchNowTicks {
    if ($script:WatchSimulationPath) { return [long](Read-WatchSimulation).now_utc_ticks }
    return [DateTime]::UtcNow.Ticks
}

function Get-WatchBootId {
    if ($script:WatchSimulationPath) { return [string](Read-WatchSimulation).boot_id }
    if (-not $script:WatchBootCached) {
        $script:WatchBootCached = [string](Get-CimInstance Win32_OperatingSystem `
            -OperationTimeoutSec 5 -ErrorAction Stop).LastBootUpTime.ToUniversalTime().Ticks
    }
    return $script:WatchBootCached
}

function Write-WatchLog {
    param([string]$Event, [hashtable]$Details = @{})
    try {
        $record = [ordered]@{ timestamp = [DateTime]::UtcNow.ToString("o"); event = $Event }
        foreach ($key in $Details.Keys) { $record[$key] = $Details[$key] }
        $record | ConvertTo-Json -Depth 8 -Compress |
            Add-Content -LiteralPath (Get-WatchPath "logs/disk-watchdog.jsonl") -Encoding UTF8
    } catch { }
}

function Get-WatchMutexName {
    param([string]$Suffix = "State")
    $hash = [Security.Cryptography.SHA256]::Create()
    try {
        $canonicalRoot = [IO.Path]::GetFullPath($script:WatchRoot).TrimEnd(
            [IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar).ToLowerInvariant()
        $bytes = [Text.Encoding]::UTF8.GetBytes($canonicalRoot)
        $key = ([BitConverter]::ToString($hash.ComputeHash($bytes))).Replace("-", "")
        return "Global\IscsiResetDiskWatcher-$key-$Suffix"
    } finally { $hash.Dispose() }
}

function New-WatchMutex {
    param([string]$Suffix = "State")
    return New-Object Threading.Mutex($false, (Get-WatchMutexName $Suffix))
}

function Invoke-WatchLocked {
    param([Parameter(Mandatory = $true)][scriptblock]$Action)
    $mutex = New-WatchMutex
    $acquired = $false
    try {
        try { $acquired = $mutex.WaitOne(10000) }
        catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { throw "Watcher state lock timed out" }
        & $Action
    } finally {
        if ($acquired) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Get-WatchConfig {
    $config = Read-WatchJson -Path (Get-WatchPath "disk-watchdog.json")
    if ($config.schema_version -ne 1 -or $config.enabled -isnot [bool]) {
        throw "Invalid watcher configuration"
    }
    return $config
}

function Get-WatchState {
    # Callers create/save runtime state under the shared state mutex. Nothing is required
    # to survive a boot: shadow mode may restore an old file or remove it entirely.
    param([string]$BootId)
    $path = Get-WatchPath "disk-watchdog-state.json"
    $latched = $false
    $lastRecord = 0
    if (Test-Path -LiteralPath $path) {
        $state = Read-WatchJson -Path $path
        $storedBoot = [long]0
        if (-not [long]::TryParse([string]$state.boot_id, [ref]$storedBoot) -or $storedBoot -le 0) {
            throw "Invalid watcher boot identity"
        }
        if ([string]$state.boot_id -eq $BootId) {
            if ($state.session_latched -isnot [bool] -or $state.last_event_record -lt 0) {
                throw "Invalid watcher protection state"
            }
            if ($state.schema_version -eq 2) {
                if ($state.install_blocked -isnot [bool] -or $state.reboot_requested -isnot [bool] -or
                    $state.failures -lt 0) { throw "Invalid watcher state" }
                return $state
            }
            if ($state.schema_version -ne 1) { throw "Unsupported watcher state" }
            # Upgrade a current-boot v1 state disarmed, retaining its session protection.
            $latched = $state.session_latched
            $lastRecord = $state.last_event_record
        }
    }
    return [pscustomobject]@{
        schema_version = 2; boot_id = $BootId; session_latched = $latched
        install_blocked = $false; reboot_requested = $false
        arm = $null; incident = $null; failures = 0
        last_event_record = $lastRecord; last_health = "waiting"
    }
}

function Save-WatchState {
    param($State)
    Write-WatchJson -Path (Get-WatchPath "disk-watchdog-state.json") -Value $State
}

function Set-WatchHealthState {
    param($State, [string]$Health)
    if ($State.last_health -ne $Health) {
        Write-WatchLog "observation_state_changed" @{ previous = $State.last_health; state = $Health }
        $State.last_health = $Health
    }
}

function Test-WatchFastLatch {
    param([string]$BootId)
    $path = Get-WatchPath "disk-watchdog-session.json"
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    $latch = Read-WatchJson -Path $path
    if ($latch.schema_version -ne 1 -or [long]$latch.observed_utc_ticks -le 0) {
        throw "Invalid watcher session latch"
    }
    return [long]$latch.observed_utc_ticks -ge [long]$BootId
}

function Get-WatchEventState {
    param([string]$BootId)
    if ($script:WatchSimulationPath) {
        $simulation = Read-WatchSimulation
        if ($simulation.event_error) { throw "Event history unavailable" }
        return [pscustomobject]@{
            SeenSession = [bool]$simulation.session_started
            RecordId = [long]$simulation.event_record_id
        }
    }
    $latest = Get-WinEvent -LogName Application -MaxEvents 1 -ErrorAction Stop
    $boot = [DateTime]::SpecifyKind([DateTime]::MinValue.AddTicks([long]$BootId), [DateTimeKind]::Utc)
    $seen = $false
    try {
        $event = Get-WinEvent -FilterHashtable @{
            LogName = "Application"; ProviderName = "esme"; Id = 2001; StartTime = $boot
        } -MaxEvents 1 -ErrorAction Stop
        $seen = $null -ne $event
    } catch {
        if ($_.FullyQualifiedErrorId -notlike "NoMatchingEventsFound*") { throw "Event history unavailable" }
    }
    return [pscustomobject]@{ SeenSession = $seen; RecordId = [long]$latest.RecordId }
}

function Test-WatchSessionAllowed {
    param($State)
    if ($State.session_latched -or (Test-WatchFastLatch -BootId $State.boot_id)) {
        $State.session_latched = $true
        return $false
    }
    $events = Get-WatchEventState -BootId $State.boot_id
    if ($events.RecordId -lt $State.last_event_record) { throw "Application event history was cleared" }
    $State.last_event_record = $events.RecordId
    if ($events.SeenSession) { $State.session_latched = $true; return $false }
    return $true
}

function Add-WatchSimulationCommand {
    param([string]$Name, [hashtable]$Details = @{})
    $simulation = Read-WatchSimulation
    $simulation.commands = @($simulation.commands) + @([pscustomobject]@{ name = $Name; details = $Details })
    Write-WatchJson -Path $script:WatchSimulationPath -Value $simulation
}

function Invoke-WatchShutdown {
    param([string]$Id)
    if ($script:WatchSimulationPath) {
        Add-WatchSimulationCommand -Name "reboot_requested" -Details @{ id = $Id; delay_seconds = 0 }
        return
    }
    $arguments = "/r /f /t 0 /d p:4:1 /c `"iSCSI disk watcher $Id`""
    $process = Start-Process -FilePath (Join-Path $env:SystemRoot "System32/shutdown.exe") `
        -ArgumentList $arguments -PassThru -WindowStyle Hidden -ErrorAction Stop
    try {
        if (-not $process.WaitForExit(5000)) { throw "Shutdown command timed out" }
        if ($process.ExitCode -ne 0) { throw "Shutdown command failed" }
    } finally { $process.Dispose() }
}

function Stop-WatchTask {
    if ($script:WatchSimulationPath) { Add-WatchSimulationCommand "watcher_stopped"; return }
    Stop-ScheduledTask -TaskPath $script:WatchTaskPath -TaskName $script:WatchTaskName -ErrorAction Stop
}

function Set-WatchSessionStarted {
    # This write must precede waiting for the state lock, including while HTTP is in flight.
    try {
        Write-WatchJson -Path (Get-WatchPath "disk-watchdog-session.json") -Value @{
            schema_version = 1; observed_utc_ticks = [string](Get-WatchNowTicks)
        }
        $bootId = Get-WatchBootId
        Invoke-WatchLocked {
            $state = Get-WatchState -BootId $bootId
            $state.session_latched = $true
            $state.arm = $null
            Save-WatchState $state
            Write-WatchLog "session_latched"
        }
    } finally { Stop-WatchTask }
}

function Reset-WatchObservation {
    $bootId = Get-WatchBootId
    Invoke-WatchLocked {
        $state = Get-WatchState -BootId $bootId
        $state.arm = $null; $state.failures = 0; $state.incident = $null
        Save-WatchState $state
        Write-WatchLog "reset_starting"
    }
}

function Normalize-WatchDiskId {
    param([string]$Value)
    $value = ($Value -replace "\s", "").ToLowerInvariant()
    if ($value.StartsWith("0x")) { $value = $value.Substring(2) }
    if ($value -notmatch '^[0-9a-f]+$') { throw "Invalid watcher NAA" }
    return $value
}

function Assert-WatchArm {
    param($Arm, [string]$BootId)
    if ([string]$Arm.boot_id -ne $BootId -or
        [string]::IsNullOrWhiteSpace([string]$Arm.target_iqn) -or
        [string]::IsNullOrWhiteSpace([string]$Arm.session_identifier) -or
        [string]::IsNullOrWhiteSpace([string]$Arm.generation) -or
        @($Arm.disk_unique_ids).Count -eq 0) { throw "Invalid watcher arm" }
    $seen = @{}
    foreach ($id in @($Arm.disk_unique_ids)) {
        $normalized = Normalize-WatchDiskId ([string]$id)
        if ($normalized -cne [string]$id) { throw "Non-canonical watcher NAA" }
        if ($seen.ContainsKey($normalized)) { throw "Duplicate watcher NAA" }
        $seen[$normalized] = $true
    }
}

function Test-WatchResetGeneration {
    param($Arm)
    $path = Get-WatchPath "disk-watchdog-reset.json"
    if (-not (Test-Path -LiteralPath $path)) { return [string]$Arm.reset_id -eq "" }
    $marker = Read-WatchJson $path
    if ($marker.schema_version -ne 1 -or -not [string]$marker.reset_id) { throw "Invalid reset marker" }
    return [string]$marker.reset_id -eq [string]$Arm.reset_id
}

function Get-WatchNativeSessions {
    return @(Get-IscsiSession -ErrorAction Stop)
}

function Get-WatchNativeDisks {
    param($Session)
    return @($Session | Get-Disk -ErrorAction Stop)
}

function Get-WatchDiskHealth {
    param($Arm)
    Assert-WatchArm -Arm $Arm -BootId (Get-WatchBootId)
    if ($script:WatchSimulationPath) {
        $simulation = Read-WatchSimulation
        if ($simulation.storage_error) { throw "Storage query failed" }
        $sessions = @($simulation.sessions | Where-Object {
            $_.target_iqn -eq $Arm.target_iqn -and $_.session_identifier -eq $Arm.session_identifier
        })
        $disks = @($simulation.disks | Where-Object target_iqn -eq $Arm.target_iqn |
            ForEach-Object {
                [pscustomobject]@{ UniqueId = $_.unique_id; IsOffline = $_.is_offline; OfflineReason = $_.offline_reason }
            })
    } else {
        $sessions = @(Get-WatchNativeSessions | Where-Object {
            $_.TargetNodeAddress -eq $Arm.target_iqn -and $_.SessionIdentifier -eq $Arm.session_identifier
        })
        $disks = @()
        if ($sessions.Count -eq 1) { $disks = @(Get-WatchNativeDisks -Session $sessions[0]) }
    }
    if ($sessions.Count -gt 1) { throw "Ambiguous watcher session" }
    $faults = @()
    if ($sessions.Count -eq 0) {
        $faults += [pscustomobject]@{ reason = "session_missing"; disk_unique_id = "" }
    } else {
        foreach ($id in @($Arm.disk_unique_ids)) {
            $matches = @($disks | Where-Object { (Normalize-WatchDiskId ([string]$_.UniqueId)) -eq $id })
            if ($matches.Count -gt 1) { throw "Ambiguous watcher NAA" }
            if ($matches.Count -eq 0) {
                $faults += [pscustomobject]@{ reason = "disk_missing"; disk_unique_id = $id }
            } elseif ($matches[0].IsOffline -isnot [bool]) { throw "Unknown disk state" }
            elseif ($matches[0].IsOffline) {
                $faults += [pscustomobject]@{
                    reason = "disk_offline"; disk_unique_id = $id
                    offline_reason = $matches[0].OfflineReason
                }
            }
        }
    }
    return [pscustomobject]@{ Healthy = $faults.Count -eq 0; Faults = $faults }
}

function Set-WatchArm {
    param($VerifiedSnapshot)
    $bootId = Get-WatchBootId
    $config = Get-WatchConfig
    if (-not $config.enabled) { return }
    $arm = [pscustomobject]@{
        boot_id = $bootId; generation = [Guid]::NewGuid().ToString("D")
        request_id = [string]$VerifiedSnapshot.request_id
        reset_id = [string]$VerifiedSnapshot.reset_id
        target_iqn = [string]$VerifiedSnapshot.target_iqn
        session_identifier = [string]$VerifiedSnapshot.session_identifier
        disk_unique_ids = @($VerifiedSnapshot.disk_unique_ids | ForEach-Object { Normalize-WatchDiskId ([string]$_) })
    }
    Assert-WatchArm $arm $bootId
    $canArm = Invoke-WatchLocked {
        $state = Get-WatchState -BootId $bootId
        $allowed = (Test-WatchSessionAllowed $state) -and -not $state.install_blocked -and -not $state.reboot_requested
        if (-not $allowed) { $state.arm = $null }
        Save-WatchState $state
        return $allowed
    }
    if (-not $canArm) { Write-WatchLog "arm_blocked"; return }
    if (-not (Test-WatchResetGeneration $arm)) { throw "Reset generation changed before arm" }
    if (-not (Get-WatchDiskHealth $arm).Healthy) { throw "Cannot arm an unhealthy disk set" }
    Invoke-WatchLocked {
        $state = Get-WatchState -BootId $bootId
        if (-not (Test-WatchSessionAllowed $state) -or $state.install_blocked -or $state.reboot_requested) {
            $state.arm = $null
            Save-WatchState $state
            Write-WatchLog "arm_blocked_by_session"
            return
        }
        $state.arm = $arm; $state.failures = 0; $state.incident = $null
        Save-WatchState $state
        Write-WatchLog "armed" @{ request_id = $arm.request_id; target_iqn = $arm.target_iqn; disk_unique_ids = $arm.disk_unique_ids }
    }
}

function Test-WatchGenerationAllowed {
    param([string]$Generation)
    $bootId = Get-WatchBootId
    return Invoke-WatchLocked {
        $state = Get-WatchState -BootId $bootId
        $config = Get-WatchConfig
        $allowed = $config.enabled -and -not $state.install_blocked -and -not $state.reboot_requested -and
            $null -ne $state.arm -and [string]$state.arm.generation -eq $Generation
        if (-not $config.enabled -or $state.install_blocked) { $state.arm = $null }
        if ($allowed -and -not (Test-WatchResetGeneration $state.arm)) {
            $state.arm = $null; $allowed = $false
        }
        if (-not (Test-WatchSessionAllowed $state)) {
            $state.arm = $null
            $allowed = $false
        }
        Save-WatchState $state
        return $allowed
    }
}

function Get-WatchDrovaCredentials {
    $base = $null; $esme = $null; $server = $null
    try {
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
            [Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
        $esme = $base.OpenSubKey("SOFTWARE\ITKey\Esme")
        if ($null -eq $esme) { throw "Missing Drova identity" }
        $id = [Guid]::Parse([string]$esme.GetValue("last_server")).ToString("D")
        $server = $esme.OpenSubKey("servers\$id")
        if ($null -eq $server) { throw "Missing Drova credentials" }
        $token = ([string]$server.GetValue("auth_token")).Trim()
        if (-not $token) { throw "Missing Drova credentials" }
        return [pscustomobject]@{ ServerId = $id; Token = $token }
    } finally {
        foreach ($key in @($server, $esme, $base)) { if ($null -ne $key) { $key.Dispose() } }
    }
}

function Invoke-WatchOfflinePost {
    if ($script:WatchSimulationPath) {
        $simulation = Read-WatchSimulation
        $codes = @($simulation.report_status_codes)
        $code = if ($codes.Count) { [int]$codes[0] } else { 200 }
        if ($codes.Count) { $simulation.report_status_codes = @($codes | Select-Object -Skip 1) }
        Write-WatchJson -Path $script:WatchSimulationPath -Value $simulation
        Add-WatchSimulationCommand "report_offline" @{ status_code = $code }
        if ($code -lt 200 -or $code -ge 300) { throw "Simulated report failure" }
        return
    }
    $credentials = $null
    try {
        $credentials = Get-WatchDrovaCredentials
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Invoke-RestMethod -Method Post `
            -Uri ("https://services.drova.io/server-manager/servers/{0}/report-offline" -f $credentials.ServerId) `
            -Headers @{ "X-Auth-Token" = $credentials.Token } -ContentType "application/json" `
            -Body '{}' -TimeoutSec 10 -MaximumRedirection 0 -ErrorAction Stop | Out-Null
    } finally { $credentials = $null }
}

function Wait-WatchSeconds {
    param([int]$Seconds)
    if ($script:WatchSimulationPath) {
        $simulation = Read-WatchSimulation
        $simulation.now_utc_ticks = [string]([long]$simulation.now_utc_ticks + [TimeSpan]::FromSeconds($Seconds).Ticks)
        Write-WatchJson -Path $script:WatchSimulationPath -Value $simulation
    } else { Start-Sleep -Seconds $Seconds }
}

function Send-WatchOfflineBatch {
    param([string]$Generation)
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        if (-not (Test-WatchGenerationAllowed $Generation)) { return $false }
        $success = $false
        try { Invoke-WatchOfflinePost; $success = $true } catch { }
        # Never log response bodies, exceptions, credentials or headers.
        Write-WatchLog "report_offline_result" @{ attempt = $attempt; success = $success }
        if (-not (Test-WatchGenerationAllowed $Generation)) { return $false }
        if ($success) { return $true }
        if ($attempt -lt 3) { Wait-WatchSeconds 5 }
    }
    return $true
}

function Request-WatchReboot {
    param([string]$Generation)
    if (-not (Test-WatchGenerationAllowed $Generation)) { return $false }
    $bootId = Get-WatchBootId
    Invoke-WatchLocked {
        $state = Get-WatchState -BootId $bootId
        $config = Get-WatchConfig
        if (-not $config.enabled -or $state.install_blocked -or $state.reboot_requested -or
            $null -eq $state.arm -or $state.arm.generation -ne $Generation) { return $false }
        if (-not (Test-WatchSessionAllowed $state) -or -not (Test-WatchResetGeneration $state.arm)) {
            $state.arm = $null; Save-WatchState $state
            return $false
        }
        $id = $state.incident.id
        # Persist intent before the command: there is no cancellable phase after /t 0.
        $state.reboot_requested = $true
        Save-WatchState $state
        try {
            Write-WatchLog "reboot_request_prepared" @{ incident_id = $id; delay_seconds = 0 }
            if (-not (Test-WatchSessionAllowed $state) -or -not (Test-WatchResetGeneration $state.arm) -or
                (Test-WatchFastLatch $bootId)) {
                $state.reboot_requested = $false; $state.arm = $null; Save-WatchState $state
                Write-WatchLog "reboot_blocked"
                return $false
            }
            Invoke-WatchShutdown -Id $id
            Write-WatchLog "reboot_accepted" @{ incident_id = $id; delay_seconds = 0 }
            return $true
        } catch {
            $state.reboot_requested = $false
            Save-WatchState $state
            throw "Reboot request failed"
        }
    }
}

function Invoke-WatchTick {
    $bootId = Get-WatchBootId
    $config = Get-WatchConfig
    if (-not $config.enabled) {
        Invoke-WatchLocked {
            $state = Get-WatchState -BootId $bootId
            $state.arm = $null; Save-WatchState $state
        }
        return "waiting"
    }
    $observation = Invoke-WatchLocked {
        $state = Get-WatchState -BootId $bootId
        if (-not (Test-WatchSessionAllowed $state)) {
            $state.arm = $null; Save-WatchState $state
            return [pscustomobject]@{ arm = $null; stopped = $true; requested = $false }
        }
        if ($state.install_blocked) { $state.arm = $null }
        if ($null -ne $state.arm -and -not (Test-WatchResetGeneration $state.arm)) {
            $state.arm = $null; $state.failures = 0; $state.incident = $null
        }
        Save-WatchState $state
        return [pscustomobject]@{ arm = $state.arm; stopped = $false; requested = $state.reboot_requested }
    }
    if ($observation.stopped) { return "stopped" }
    if ($observation.requested) { return "reboot_requested" }
    $arm = $observation.arm
    if ($null -eq $arm) {
        return "waiting"
    }
    $health = $null
    try { $health = Get-WatchDiskHealth $arm } catch { Write-WatchLog "storage_query_error" }
    $decision = Invoke-WatchLocked {
        $state = Get-WatchState -BootId $bootId
        if ($null -eq $state.arm -or $state.arm.generation -ne $arm.generation) { return "waiting" }
        if ($state.reboot_requested) { return "reboot_requested" }
        if ($null -eq $health) {
            $state.failures = 0; Set-WatchHealthState $state "unknown"
            Save-WatchState $state; return "unknown"
        }
        if ($health.Healthy) {
            $state.failures = 0; $state.incident = $null
            Set-WatchHealthState $state "healthy"
            Save-WatchState $state; return "healthy"
        }
        $state.failures++
        if ($state.failures -lt 3) {
            Set-WatchHealthState $state "suspect"; Save-WatchState $state; return "suspect"
        }
        Set-WatchHealthState $state "failed"
        if ($null -eq $state.incident) {
            $state.incident = [pscustomobject]@{
                id = [Guid]::NewGuid().ToString("D"); notified = $false
            }
            Write-WatchLog "disk_failure_confirmed" @{ faults = $health.Faults; request_id = $arm.request_id }
        }
        Save-WatchState $state
        if ($state.incident.notified) { return "reboot" }
        return "notify"
    }
    if ($decision -in @("notify", "reboot")) {
        if ($decision -eq "notify") {
            if (-not (Send-WatchOfflineBatch $arm.generation)) {
                if ((Get-WatchState -BootId $bootId).session_latched) { return "stopped" }
                return "waiting"
            }
            Invoke-WatchLocked {
                $state = Get-WatchState -BootId $bootId
                if ($null -ne $state.arm -and $state.arm.generation -eq $arm.generation -and $null -ne $state.incident) {
                    $state.incident.notified = $true; Save-WatchState $state
                }
            }
        }
        if (Request-WatchReboot $arm.generation) { return "reboot_requested" }
        if ((Get-WatchState -BootId $bootId).session_latched) { return "stopped" }
        return "waiting"
    }
    return $decision
}

function Invoke-WatchMain {
    $mutex = New-WatchMutex "Worker"
    $acquired = $false
    try {
        try { $acquired = $mutex.WaitOne(0) }
        catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { return }
        Write-WatchLog "watcher_started"
        while ($true) {
            try { $result = Invoke-WatchTick }
            catch {
                Write-WatchLog "watcher_guard_error"
                try { Reset-WatchObservation } catch { }
                return
            }
            if ($result -in @("stopped", "reboot_requested")) { return }
            Wait-WatchSeconds 5
        }
    } finally {
        if ($acquired) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

if (-not $NoMain) {
    try {
        switch ($Mode) {
            "Watch" { Invoke-WatchMain }
            "SessionStarted" { Set-WatchSessionStarted }
            "ResetStarting" { Reset-WatchObservation }
            "Arm" { Set-WatchArm -VerifiedSnapshot $Snapshot }
        }
    } catch {
        Write-WatchLog "watcher_operation_failed" @{ mode = $Mode }
        throw "iSCSI disk watcher operation failed; see protected log"
    }
}
