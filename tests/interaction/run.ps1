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

Write-Host "Interaction suite passed"
