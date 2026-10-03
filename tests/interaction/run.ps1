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
            if (-not $disk.is_offline -or $null -ne $disk.drive_letter) {
                throw "Read-only attempt changed a simulated disk before retry"
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

Write-Host "Interaction suite passed"
