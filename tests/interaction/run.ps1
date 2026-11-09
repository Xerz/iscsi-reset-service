$ErrorActionPreference = "Stop"
$root = "/tmp/iscsi-reset-interaction"
New-Item -ItemType Directory -Path $root -Force | Out-Null
$tokenPath = Join-Path $root "client.token"
$statePath = Join-Path $root "windows-state.json"
Set-Content -LiteralPath $tokenPath -Value "chimera-interaction-token" -NoNewline

# The simulation shares management's network namespace, matching an SSH tunnel endpoint.
$managementOrigin = "http://127.0.0.1:8445"
$loginBody = @{ token = "management-test-token" } | ConvertTo-Json
$login = Invoke-RestMethod `
    -Method Post `
    -Uri "$managementOrigin/v1/management/session" `
    -Headers @{ Origin = $managementOrigin } `
    -ContentType "application/json" `
    -Body $loginBody `
    -SessionVariable managementSession
$managementHeaders = @{
    Origin = $managementOrigin
    "X-CSRF-Token" = [string]$login.csrf_token
}
$staged = Invoke-RestMethod `
    -Method Post `
    -Uri "$managementOrigin/v1/management/releases/stage" `
    -Headers $managementHeaders `
    -WebSession $managementSession
if ([string]$staged.status -ne "staged") { throw "Release was not staged" }
$body = @{ confirmation = "ACTIVATE $($staged.release)" } | ConvertTo-Json
$activated = Invoke-RestMethod `
    -Method Post `
    -Uri "$managementOrigin/v1/management/releases/$($staged.release)/activate" `
    -Headers $managementHeaders `
    -ContentType "application/json" `
    -Body $body `
    -WebSession $managementSession
if ([string]$activated.status -ne "active") { throw "Release was not activated" }
$dashboard = Invoke-RestMethod `
    -Method Get `
    -Uri "$managementOrigin/v1/management/dashboard" `
    -WebSession $managementSession
if ([string]$dashboard.active_release -ne [string]$staged.release) {
    throw "Dashboard did not report the activated release"
}
$document = Invoke-RestMethod `
    -Method Get `
    -Uri "$managementOrigin/v1/management/config" `
    -WebSession $managementSession
$document.config.clients.chimera.volumes.ssd.label = "COMPOSE_CONFIG"
$validateBody = @{
    base_revision = [string]$document.source_revision
    config = $document.config
} | ConvertTo-Json -Depth 20
$validated = Invoke-RestMethod `
    -Method Post `
    -Uri "$managementOrigin/v1/management/config/validate" `
    -Headers $managementHeaders `
    -ContentType "application/json" `
    -Body $validateBody `
    -WebSession $managementSession
$saveBody = @{
    base_revision = [string]$document.source_revision
    yaml = [string]$validated.yaml
} | ConvertTo-Json -Depth 5
$saved = Invoke-RestMethod `
    -Method Put `
    -Uri "$managementOrigin/v1/management/config" `
    -Headers $managementHeaders `
    -ContentType "application/json" `
    -Body $saveBody `
    -WebSession $managementSession
if (-not [bool]$saved.restart_required) {
    throw "Management save did not require a Custom App restart"
}
$managementStatus = Invoke-RestMethod `
    -Method Get `
    -Uri "$managementOrigin/v1/management/status" `
    -WebSession $managementSession
if ([string]$managementStatus.saved_revision -eq [string]$managementStatus.startup_revision) {
    throw "Management revisions did not diverge after save"
}

@{
    sessions = @()
    disks = @(
        @{
            target_iqn = "iqn.2026-08.lab.games:chimera"
            unique_id = "0x6589cfc000000001"
            label = "GAMES_SSD"
            drive_letter = $null
            is_offline = $true
            is_read_only = $false
        },
        @{
            target_iqn = "iqn.2026-08.lab.games:chimera"
            unique_id = "0x6589cfc000000002"
            label = "GAMES_HDD"
            drive_letter = $null
            is_offline = $true
            is_read_only = $false
        },
        @{
            target_iqn = "local"
            unique_id = "local-system-disk"
            label = "WINDOWS"
            drive_letter = "C"
            is_offline = $false
            is_read_only = $false
        }
    )
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $statePath

$code = & "/suite/powershell/Reset-And-Connect.ps1" `
    -ApiBaseUrl "http://api:8080" `
    -TokenPath $tokenPath `
    -WaitTimeoutSeconds 30 `
    -SimulationStatePath $statePath `
    -SimulationSourceIp "10.20.40.101" `
    -AllowHttpForSimulation `
    -PassThruExitCode
if ([int]$code -ne 0) { throw "Successful interaction returned exit code $code" }

$state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
if (@($state.sessions).Count -ne 1) { throw "Expected one simulated session" }
if (($state.disks | Where-Object unique_id -eq "0x6589cfc000000001").drive_letter -ne "S") {
    throw "SSD letter was not assigned"
}
if (($state.disks | Where-Object unique_id -eq "0x6589cfc000000002").drive_letter -ne "H") {
    throw "HDD letter was not assigned"
}
if (($state.disks | Where-Object unique_id -eq "local-system-disk").drive_letter -ne "C") {
    throw "Local disk was modified"
}

# A wrong NAA must fail after connection and remove the newly created session.
# Do not spend nineteen real minutes on the permanent validation-error scenario.
function Start-Sleep {
    param([int]$Seconds, [int]$Milliseconds)
    if ($Seconds -eq 60) { return }
    if ($PSBoundParameters.ContainsKey("Seconds")) {
        Microsoft.PowerShell.Utility\Start-Sleep -Seconds $Seconds
    } else {
        Microsoft.PowerShell.Utility\Start-Sleep -Milliseconds $Milliseconds
    }
}
$state.sessions = @()
($state.disks | Where-Object unique_id -eq "0x6589cfc000000001").unique_id = "wrong-naa"
$state | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $statePath
$code = & "/suite/powershell/Reset-And-Connect.ps1" `
    -ApiBaseUrl "http://api:8080" `
    -TokenPath $tokenPath `
    -WaitTimeoutSeconds 15 `
    -SimulationStatePath $statePath `
    -SimulationSourceIp "10.20.40.101" `
    -AllowHttpForSimulation `
    -PassThruExitCode
if ([int]$code -ne 40) { throw "Wrong NAA returned exit code $code instead of 40" }
$state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
if (@($state.sessions).Count -ne 0) { throw "Failed disk validation left a session connected" }
$failureRecords = @(Get-Content -LiteralPath (Join-Path $root "client.log.jsonl") | ConvertFrom-Json)
if (@($failureRecords | Where-Object event -eq "attempt_retry").Count -ne 19) {
    throw "Permanent NAA mismatch did not retry nineteen times"
}
if (($state.disks | Where-Object unique_id -eq "local-system-disk").drive_letter -ne "C") {
    throw "Wrong-NAA scenario modified the local disk"
}

# Exercise a complete read-only retry against the real mock API, including the minute pause.
($state.disks | Where-Object unique_id -eq "wrong-naa").unique_id = "0x6589cfc000000001"
foreach ($disk in @($state.disks | Where-Object target_iqn -eq "iqn.2026-08.lab.games:chimera")) {
    $disk.is_offline = $true
    $disk.drive_letter = $null
}
($state.disks | Where-Object unique_id -eq "0x6589cfc000000001").is_read_only = $true
$state | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $statePath
Remove-Item -LiteralPath (Join-Path $root "client.log.jsonl") -Force
. "/suite/powershell/Reset-And-Connect.ps1" `
    -TokenPath $tokenPath `
    -SimulationStatePath $statePath -SimulationSourceIp "10.20.40.101" `
    -AllowHttpForSimulation -NoMain
$script:ReadOnlyPauseCount = 0
function Start-Sleep {
    param([int]$Seconds, [int]$Milliseconds)
    if ($Seconds -eq 60) {
        $script:ReadOnlyPauseCount++
        if (@(Get-ResetSessions -TargetIqn "iqn.2026-08.lab.games:chimera").Count -ne 0) {
            throw "Read-only retry started before the session was removed"
        }
        $retryState = Read-SimulationState
        foreach ($disk in @($retryState.disks | Where-Object target_iqn -eq "iqn.2026-08.lab.games:chimera")) {
            if ($null -ne $disk.drive_letter) {
                throw "Read-only attempt assigned a drive letter before retry"
            }
        }
        Microsoft.PowerShell.Utility\Start-Sleep -Seconds $Seconds
        # Model recovery of the observed Windows read-only state after logout and the pause.
        ($retryState.disks | Where-Object unique_id -eq "0x6589cfc000000001").is_read_only = $false
        Save-SimulationState $retryState
    } elseif ($PSBoundParameters.ContainsKey("Seconds")) {
        Microsoft.PowerShell.Utility\Start-Sleep -Seconds $Seconds
    } else {
        Microsoft.PowerShell.Utility\Start-Sleep -Milliseconds $Milliseconds
    }
}
$code = Invoke-ResetMain -BaseUrl "http://api:8080" -ClientTokenPath $tokenPath `
    -TimeoutSeconds 15
if ($code -ne 0 -or $script:ReadOnlyPauseCount -ne 1) {
    throw "Read-only retry did not succeed after exactly one minute pause"
}
$records = @(Get-Content -LiteralPath (Join-Path $root "client.log.jsonl") | ConvertFrom-Json)
foreach ($event in @("start", "api_ready", "client_configuration_loaded", "prepared", "target_discovered", "target_connected")) {
    if (@($records | Where-Object event -eq $event).Count -ne 2) {
        throw "Read-only retry did not repeat stage $event"
    }
}
$starts = @($records | Where-Object event -eq "start")
if ($starts[0].request_id -eq $starts[1].request_id) { throw "Retry reused the previous request ID" }
if (@($records | Where-Object event -eq "ready").Count -ne 1) { throw "Unexpected ready count" }
$state = Read-SimulationState
if (@($state.sessions).Count -ne 1) { throw "Retry did not leave one verified session" }
foreach ($disk in @($state.disks | Where-Object target_iqn -eq "iqn.2026-08.lab.games:chimera")) {
    if ($disk.is_offline -or [string]::IsNullOrWhiteSpace($disk.drive_letter)) {
        throw "Retry did not mount the complete simulated disk set"
    }
}
if (($state.disks | Where-Object unique_id -eq "local-system-disk").drive_letter -ne "C") {
    throw "Read-only retry modified the local disk"
}

# Model delayed writable discovery inside one session, with real one-second pauses.
$state.sessions = @()
foreach ($disk in @($state.disks | Where-Object target_iqn -eq "iqn.2026-08.lab.games:chimera")) {
    $disk.is_offline = $true
    $disk.drive_letter = $null
}
($state.disks | Where-Object unique_id -eq "0x6589cfc000000001").is_read_only = $true
Save-SimulationState $state
Remove-Item -LiteralPath (Join-Path $root "client.log.jsonl") -Force
$script:WritablePollCount = 0
function Start-Sleep {
    param([int]$Seconds, [int]$Milliseconds)
    if ($Seconds -eq 60) { throw "Transient read-only unexpectedly caused a full retry" }
    if ($Seconds -eq 1) {
        $script:WritablePollCount++
        if (@(Get-ResetSessions -TargetIqn "iqn.2026-08.lab.games:chimera").Count -ne 1) {
            throw "Writable observation lost its original session"
        }
        $observed = Read-SimulationState
        foreach ($disk in @($observed.disks | Where-Object target_iqn -eq "iqn.2026-08.lab.games:chimera")) {
            if (-not $disk.is_offline -or $null -ne $disk.drive_letter) {
                throw "Writable observation mutated a disk before readiness"
            }
        }
        Microsoft.PowerShell.Utility\Start-Sleep -Seconds 1
        if ($script:WritablePollCount -eq 2) {
            ($observed.disks | Where-Object unique_id -eq "0x6589cfc000000001").is_read_only = $false
            Save-SimulationState $observed
        }
    } elseif ($PSBoundParameters.ContainsKey("Seconds")) {
        Microsoft.PowerShell.Utility\Start-Sleep -Seconds $Seconds
    } else {
        Microsoft.PowerShell.Utility\Start-Sleep -Milliseconds $Milliseconds
    }
}
$code = Invoke-ResetMain -BaseUrl "http://api:8080" -ClientTokenPath $tokenPath `
    -TimeoutSeconds 15
if ($code -ne 0 -or $script:WritablePollCount -ne 2) {
    throw "Delayed writable discovery did not succeed in the original session"
}
$records = @(Get-Content -LiteralPath (Join-Path $root "client.log.jsonl") | ConvertFrom-Json)
foreach ($event in @("start", "prepared", "target_connected", "disk_read_only_wait", "disk_writable_after_wait", "ready")) {
    if (@($records | Where-Object event -eq $event).Count -ne 1) {
        throw "Unexpected event count after writable observation: $event"
    }
}
if (@($records | Where-Object event -eq "target_disconnected_after_error").Count -ne 0) {
    throw "Writable observation disconnected its session"
}
$state = Read-SimulationState
if (@($state.sessions).Count -ne 1) { throw "Writable observation left an unexpected session set" }
foreach ($disk in @($state.disks | Where-Object target_iqn -eq "iqn.2026-08.lab.games:chimera")) {
    if ($disk.is_offline -or [string]::IsNullOrWhiteSpace($disk.drive_letter)) {
        throw "Writable observation did not mount the complete disk set"
    }
}
if (($state.disks | Where-Object unique_id -eq "local-system-disk").drive_letter -ne "C") {
    throw "Writable observation modified the local disk"
}

# Model the reported workaround: only the simulated offline-online transition clears read-only.
$state.sessions = @()
foreach ($disk in @($state.disks | Where-Object target_iqn -eq "iqn.2026-08.lab.games:chimera")) {
    $disk.is_offline = $false
    $disk.drive_letter = $null
}
($state.disks | Where-Object unique_id -eq "0x6589cfc000000001").is_read_only = $true
Save-SimulationState $state
Remove-Item -LiteralPath (Join-Path $root "client.log.jsonl") -Force
$script:ActualDiskOfflineSetter = (Get-Command Set-ResetSessionDiskOffline).ScriptBlock
$script:CycleMutationCount = 0
function Set-ResetSessionDiskOffline {
    param($Session, $Disk, [bool]$IsOffline)
    & $script:ActualDiskOfflineSetter -Session $Session -Disk $Disk -IsOffline $IsOffline
    $script:CycleMutationCount++
    if (-not $IsOffline) {
        $observed = Read-SimulationState
        ($observed.disks | Where-Object unique_id -eq $Disk.UniqueId).is_read_only = $false
        Save-SimulationState $observed
    }
}
function Start-Sleep {
    param([int]$Seconds, [int]$Milliseconds)
    if ($Seconds -eq 60) { throw "Offline-online workaround unexpectedly caused a full retry" }
    if ($PSBoundParameters.ContainsKey("Seconds")) {
        Microsoft.PowerShell.Utility\Start-Sleep -Seconds $Seconds
    } else {
        Microsoft.PowerShell.Utility\Start-Sleep -Milliseconds $Milliseconds
    }
}
$code = Invoke-ResetMain -BaseUrl "http://api:8080" -ClientTokenPath $tokenPath `
    -TimeoutSeconds 15
$expectedMutations = @($state.disks | Where-Object target_iqn -eq "iqn.2026-08.lab.games:chimera").Count * 2
if ($code -ne 0 -or $script:CycleMutationCount -ne $expectedMutations) {
    throw "Offline-online workaround did not cycle each client disk exactly once"
}
$records = @(Get-Content -LiteralPath (Join-Path $root "client.log.jsonl") | ConvertFrom-Json)
foreach ($event in @("start", "prepared", "target_connected", "disk_offline_online_start", "disk_offline_online_ready", "ready")) {
    if (@($records | Where-Object event -eq $event).Count -ne 1) {
        throw "Unexpected event count after offline-online recovery: $event"
    }
}
if (@($records | Where-Object event -eq "target_disconnected_after_error").Count -ne 0) {
    throw "Offline-online recovery disconnected its session"
}
$state = Read-SimulationState
foreach ($disk in @($state.disks | Where-Object target_iqn -eq "iqn.2026-08.lab.games:chimera")) {
    if ($disk.is_offline -or $disk.is_read_only -or [string]::IsNullOrWhiteSpace($disk.drive_letter)) {
        throw "Offline-online recovery did not mount a complete writable disk set"
    }
}
if (($state.disks | Where-Object unique_id -eq "local-system-disk").drive_letter -ne "C") {
    throw "Offline-online recovery modified the local disk"
}

# Exercise the watcher using its real state machine and exclusively simulated side effects.
$watchRoot = Join-Path $root "disk-watchdog"
New-Item -ItemType Directory -Path (Join-Path $watchRoot "logs") -Force | Out-Null
$watchWindows = Join-Path $root "watch-windows.json"
$watchBoot = [DateTime]::UtcNow.AddMinutes(-10).Ticks
@{
    boot_id = [string]$watchBoot; now_utc_ticks = [string][DateTime]::UtcNow.Ticks
    event_record_id = 100; session_started = $false; event_error = $false; storage_error = $false
    sessions = @(@{ target_iqn = "watch-target"; session_identifier = "watch-session" })
    disks = @(
        @{ target_iqn = "watch-target"; unique_id = "aaa"; is_offline = $false; offline_reason = 0 },
        @{ target_iqn = "watch-target"; unique_id = "bbb"; is_offline = $false; offline_reason = 0 },
        @{ target_iqn = "watch-target"; unique_id = "ccc"; is_offline = $false; offline_reason = 0 }
    )
    commands = @(); report_status_codes = @(503, 503, 503)
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $watchWindows
. "/suite/powershell/Watch-IscsiDisks.ps1" -InstallRoot $watchRoot -SimulationPath $watchWindows -NoMain
Write-WatchJson (Get-WatchPath "disk-watchdog.json") @{
    schema_version = 1; enabled = $true
}
Save-WatchState (Get-WatchState -BootId ([string]$watchBoot))
Set-WatchArm ([pscustomobject]@{
    reset_id = ""; request_id = "compose-reset"; target_iqn = "watch-target"
    session_identifier = "watch-session"; disk_unique_ids = @("aaa", "bbb", "ccc")
})
if ((Invoke-WatchTick) -ne "healthy") { throw "Watcher did not accept the verified disk set" }
$watchState = Read-WatchSimulation
$watchState.disks[2].is_offline = $true
$watchState.disks[2].offline_reason = 5
Write-WatchJson $watchWindows $watchState
1..3 | ForEach-Object { $null = Invoke-WatchTick; Wait-WatchSeconds 5 }
$watchState = Read-WatchSimulation
if (@($watchState.commands | Where-Object name -eq "report_offline").Count -ne 3 -or
    @($watchState.commands | Where-Object name -eq "reboot_requested").Count -ne 1 -or
    ($watchState.commands | Where-Object name -eq "reboot_requested").details.delay_seconds -ne 0) {
    throw "Watcher did not preserve the three-report failure/reboot policy"
}
# A shadow-restored previous-boot snapshot cannot arm a new boot; current-boot 2001 blocks it.
$watchState.boot_id = [string]([long]$watchState.now_utc_ticks + [TimeSpan]::FromSeconds(1).Ticks)
$watchState.now_utc_ticks = [string]([long]$watchState.boot_id + [TimeSpan]::FromSeconds(1).Ticks)
$watchState.session_started = $true
Write-WatchJson $watchWindows $watchState
Set-WatchArm ([pscustomobject]@{
    reset_id = ""; request_id = "compose-reset-2"; target_iqn = "watch-target"
    session_identifier = "watch-session"; disk_unique_ids = @("aaa", "bbb", "ccc")
})
if ((Invoke-WatchTick) -ne "stopped") { throw "Current-boot Esme 2001 did not block monitoring" }
# Missing runtime files after another shadow reboot are recreated disarmed.
$watchState = Read-WatchSimulation
$watchState.boot_id = [string]([long]$watchState.now_utc_ticks + [TimeSpan]::FromSeconds(1).Ticks)
$watchState.now_utc_ticks = [string]([long]$watchState.boot_id + [TimeSpan]::FromSeconds(1).Ticks)
$watchState.session_started = $false
$watchState.disks[2].is_offline = $false
Write-WatchJson $watchWindows $watchState
Remove-Item (Get-WatchPath "disk-watchdog-state.json")
if ((Invoke-WatchTick) -ne "waiting") { throw "Missing shadow runtime state was not recreated disarmed" }
Set-WatchArm ([pscustomobject]@{
    reset_id = ""; request_id = "compose-reset-3"; target_iqn = "watch-target"
    session_identifier = "watch-session"; disk_unique_ids = @("aaa", "bbb", "ccc")
})
if ((Invoke-WatchTick) -ne "healthy" -or
    @((Read-WatchSimulation).commands | Where-Object name -eq "reboot_requested").Count -ne 1) {
    throw "Fresh reset did not rearm healthy disks after shadow reboot"
}

Write-Host "Interaction suite passed"
