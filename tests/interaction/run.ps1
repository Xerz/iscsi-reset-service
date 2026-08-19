$ErrorActionPreference = "Stop"
$root = "/tmp/iscsi-reset-interaction"
New-Item -ItemType Directory -Path $root -Force | Out-Null
$tokenPath = Join-Path $root "client.token"
$statePath = Join-Path $root "windows-state.json"
Set-Content -LiteralPath $tokenPath -Value "chimera-interaction-token" -NoNewline

# The simulation shares configurator's network namespace, matching an SSH tunnel endpoint.
$configuratorOrigin = "http://127.0.0.1:8445"
$loginBody = @{ token = "configurator-test-token" } | ConvertTo-Json
$login = Invoke-RestMethod `
    -Method Post `
    -Uri "$configuratorOrigin/v1/configurator/session" `
    -Headers @{ Origin = $configuratorOrigin } `
    -ContentType "application/json" `
    -Body $loginBody `
    -SessionVariable configuratorSession
$configuratorHeaders = @{
    Origin = $configuratorOrigin
    "X-CSRF-Token" = [string]$login.csrf_token
}
$document = Invoke-RestMethod `
    -Method Get `
    -Uri "$configuratorOrigin/v1/configurator/config" `
    -WebSession $configuratorSession
$document.config.clients.chimera.volumes.ssd.label = "COMPOSE_CONFIG"
$validateBody = @{
    base_revision = [string]$document.source_revision
    config = $document.config
} | ConvertTo-Json -Depth 20
$validated = Invoke-RestMethod `
    -Method Post `
    -Uri "$configuratorOrigin/v1/configurator/config/validate" `
    -Headers $configuratorHeaders `
    -ContentType "application/json" `
    -Body $validateBody `
    -WebSession $configuratorSession
$saveBody = @{
    base_revision = [string]$document.source_revision
    yaml = [string]$validated.yaml
} | ConvertTo-Json -Depth 5
$saved = Invoke-RestMethod `
    -Method Put `
    -Uri "$configuratorOrigin/v1/configurator/config" `
    -Headers $configuratorHeaders `
    -ContentType "application/json" `
    -Body $saveBody `
    -WebSession $configuratorSession
if (-not [bool]$saved.restart_required) {
    throw "Configurator save did not require a Custom App restart"
}
$configuratorStatus = Invoke-RestMethod `
    -Method Get `
    -Uri "$configuratorOrigin/v1/configurator/status" `
    -WebSession $configuratorSession
if ([string]$configuratorStatus.saved_revision -eq [string]$configuratorStatus.startup_revision) {
    throw "Configurator revisions did not diverge after save"
}

$adminHeaders = @{
    Authorization = "Bearer publisher-interaction-token"
    "X-Test-Source-IP" = "192.168.1.101"
    "X-Request-ID" = "compose-stage"
}
$staged = Invoke-RestMethod `
    -Method Post `
    -Uri "http://admin:8081/v1/admin/releases/stage" `
    -Headers $adminHeaders
if ([string]$staged.status -ne "staged") { throw "Release was not staged" }
$adminHeaders["X-Request-ID"] = "compose-activate"
$body = @{ confirmation = "ACTIVATE $($staged.release)" } | ConvertTo-Json
$activated = Invoke-RestMethod `
    -Method Post `
    -Uri "http://admin:8081/v1/admin/releases/$($staged.release)/activate" `
    -Headers $adminHeaders `
    -ContentType "application/json" `
    -Body $body
if ([string]$activated.status -ne "active") { throw "Release was not activated" }

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
