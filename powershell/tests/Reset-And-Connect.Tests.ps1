BeforeAll {
    $script:ClientScriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) "Reset-And-Connect.ps1"
    . $script:ClientScriptPath -NoMain
}

Describe "Reset-And-Connect safety helpers" {
    It "normalizes only case, whitespace, and an optional 0x prefix" {
        Normalize-DiskId " 0x65 89CF " | Should -Be "6589cf"
        Normalize-DiskId "EUI.001" | Should -Be "eui.001"
    }

    It "does not contain destructive disk provisioning commands" {
        $source = Get-Content -LiteralPath $script:ClientScriptPath -Raw
        $source | Should -Not -Match "(?im)^\s*(Initialize-Disk|Format-Volume|Clear-Disk|New-Partition)\b"
    }

    It "always creates a non-persistent iSCSI login" {
        $source = Get-Content -LiteralPath $script:ClientScriptPath -Raw
        $source | Should -Match '-IsPersistent\s+\$false'
    }
}

Describe "Simulation disk isolation" {
    BeforeEach {
        $script:SimulationStatePath = Join-Path $TestDrive "state.json"
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
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:SimulationStatePath
    }

    It "assigns letters only to exact expected IDs" {
        $state = Read-SimulationState
        $sessionDisks = @($state.disks | Where-Object { $_.target_iqn -like "*:chimera" })
        $expected = @(
            [pscustomobject]@{ name = "ssd"; disk_unique_id = "6589cfc000000001"; drive_letter = "S"; label = "GAMES_SSD" },
            [pscustomobject]@{ name = "hdd"; disk_unique_id = "6589cfc000000002"; drive_letter = "H"; label = "GAMES_HDD" }
        )

        Mount-ResetVolumes -ExpectedVolumes $expected -Disks $sessionDisks

        $after = Read-SimulationState
        ($after.disks | Where-Object unique_id -eq "local-system-disk").drive_letter | Should -Be "C"
        ($after.disks | Where-Object unique_id -eq "0x6589cfc000000001").drive_letter | Should -Be "S"
        ($after.disks | Where-Object unique_id -eq "0x6589cfc000000002").drive_letter | Should -Be "H"
    }

    It "fails without changing state when an expected ID is absent" {
        $before = Get-Content -LiteralPath $script:SimulationStatePath -Raw
        $state = Read-SimulationState
        $expected = @(
            [pscustomobject]@{ name = "ssd"; disk_unique_id = "wrong-id"; drive_letter = "S"; label = "GAMES_SSD" },
            [pscustomobject]@{ name = "hdd"; disk_unique_id = "6589cfc000000002"; drive_letter = "H"; label = "GAMES_HDD" }
        )

        { Mount-ResetVolumes -ExpectedVolumes $expected -Disks @($state.disks | Where-Object { $_.target_iqn -like "*:chimera" }) } | Should -Throw

        Get-Content -LiteralPath $script:SimulationStatePath -Raw | Should -BeExactly $before
    }

    It "fails without changing state when a requested letter belongs to another disk" {
        $state = Read-SimulationState
        ($state.disks | Where-Object unique_id -eq "local-system-disk").drive_letter = "S"
        Save-SimulationState $state
        $before = Get-Content -LiteralPath $script:SimulationStatePath -Raw
        $expected = @(
            [pscustomobject]@{ name = "ssd"; disk_unique_id = "6589cfc000000001"; drive_letter = "S"; label = "GAMES_SSD" },
            [pscustomobject]@{ name = "hdd"; disk_unique_id = "6589cfc000000002"; drive_letter = "H"; label = "GAMES_HDD" }
        )

        { Mount-ResetVolumes -ExpectedVolumes $expected -Disks @($state.disks | Where-Object { $_.target_iqn -like "*:chimera" }) } | Should -Throw

        Get-Content -LiteralPath $script:SimulationStatePath -Raw | Should -BeExactly $before
    }
}

Describe "Prepare retry policy" {
    It "reuses the request ID and retries a transient 503" {
        $script:attempt = 0
        Mock Start-Sleep { }
        Mock Invoke-ResetRequest {
            $script:attempt++
            if ($script:attempt -eq 1) {
                throw (New-ApiException -StatusCode 503 -Code "NOT_READY" -Message "injected")
            }
            return [pscustomobject]@{ status = "ready" }
        }

        $result = Invoke-PrepareWithRetry -BaseUrl "https://10.20.40.10:8443" -Token "redacted" -RequestId "same-request" -TimeoutSeconds 5

        $result.status | Should -Be "ready"
        Should -Invoke -CommandName Invoke-ResetRequest -Times 2 -Exactly -ParameterFilter { $RequestId -eq "same-request" }
    }
}

Describe "Startup flow failure handling" {
    BeforeEach {
        $script:SimulationStatePath = Join-Path $TestDrive "startup-state.json"
        $script:SimulationSourceIp = "10.20.40.101"
        $script:AllowHttpForSimulation = $true
        $script:tokenPath = Join-Path $TestDrive "client.token"
        Set-Content -LiteralPath $script:tokenPath -Value "test-token" -NoNewline
        @{
            sessions = @()
            disks = @(
                @{
                    target_iqn = "iqn.2026-08.lab.games:chimera"
                    unique_id = "wrong-naa"
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
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:SimulationStatePath
        Mock Wait-ResetApi { }
    }

    It "does not reset or disconnect a target that was already connected" {
        $state = Read-SimulationState
        $state.sessions = @([pscustomobject]@{
            target_iqn = "iqn.2026-08.lab.games:chimera"
            persistent = $false
        })
        Save-SimulationState $state
        Mock Invoke-ResetRequest {
            return [pscustomobject]@{
                target_iqn = "iqn.2026-08.lab.games:chimera"
                portal = [pscustomobject]@{ address = "10.20.40.10"; port = 3260 }
            }
        }

        $code = Invoke-ResetMain -BaseUrl "http://mock" -ClientTokenPath $script:tokenPath -TimeoutSeconds 2

        $code | Should -Be 20
        @(Get-ResetSessions -TargetIqn "iqn.2026-08.lab.games:chimera").Count | Should -Be 1
        Should -Invoke Invoke-ResetRequest -Times 1 -Exactly
    }

    It "returns an API failure without creating an iSCSI session" {
        Mock Invoke-ResetRequest {
            return [pscustomobject]@{
                target_iqn = "iqn.2026-08.lab.games:chimera"
                portal = [pscustomobject]@{ address = "10.20.40.10"; port = 3260 }
            }
        }
        Mock Invoke-PrepareWithRetry {
            throw (New-ApiException -StatusCode 503 -Code "NOT_READY" -Message "injected")
        }

        $code = Invoke-ResetMain -BaseUrl "http://mock" -ClientTokenPath $script:tokenPath -TimeoutSeconds 2

        $code | Should -Be 20
        @((Read-SimulationState).sessions).Count | Should -Be 0
    }

    It "disconnects the newly-created session when NAA validation fails" {
        Mock Invoke-ResetRequest {
            if ($Uri.EndsWith("/v1/client")) {
                return [pscustomobject]@{
                    target_iqn = "iqn.2026-08.lab.games:chimera"
                    portal = [pscustomobject]@{ address = "10.20.40.10"; port = 3260 }
                }
            }
            return [pscustomobject]@{
                target_iqn = "iqn.2026-08.lab.games:chimera"
                portal = [pscustomobject]@{ address = "10.20.40.10"; port = 3260 }
                volumes = @(
                    [pscustomobject]@{ name = "ssd"; disk_unique_id = "6589cfc000000001"; drive_letter = "S"; label = "GAMES_SSD" },
                    [pscustomobject]@{ name = "hdd"; disk_unique_id = "6589cfc000000002"; drive_letter = "H"; label = "GAMES_HDD" }
                )
            }
        }

        $code = Invoke-ResetMain -BaseUrl "http://mock" -ClientTokenPath $script:tokenPath -TimeoutSeconds 2

        $code | Should -Be 40
        $state = Read-SimulationState
        @($state.sessions).Count | Should -Be 0
        ($state.disks | Where-Object unique_id -eq "local-system-disk").drive_letter | Should -Be "C"
    }
}
