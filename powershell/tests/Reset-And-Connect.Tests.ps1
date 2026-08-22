BeforeAll {
    $script:ClientScriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) "Reset-And-Connect.ps1"
    . $script:ClientScriptPath -NoMain
    if ($null -eq (Get-Command Set-Disk -ErrorAction SilentlyContinue)) {
        Set-Item -Path "function:Set-Disk" -Value { param($Number, $IsOffline) }
    }
    if ($null -eq (Get-Command Get-Partition -ErrorAction SilentlyContinue)) {
        Set-Item -Path "function:Get-Partition" -Value {
            param($DiskNumber, $DriveLetter, $ErrorAction)
        }
    }
    if ($null -eq (Get-Command Set-Partition -ErrorAction SilentlyContinue)) {
        Set-Item -Path "function:Set-Partition" -Value {
            param($DiskNumber, $PartitionNumber, $NewDriveLetter)
        }
    }
    if ($null -eq (Get-Command Remove-PartitionAccessPath -ErrorAction SilentlyContinue)) {
        Set-Item -Path "function:Remove-PartitionAccessPath" -Value {
            param($DiskNumber, $PartitionNumber, $AccessPath, $Confirm)
        }
    }
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

    It "only removes access paths and never removes partitions" {
        $source = Get-Content -LiteralPath $script:ClientScriptPath -Raw
        $source | Should -Match '(?im)^\s*Remove-PartitionAccessPath\b'
        $source | Should -Not -Match '(?im)^\s*Remove-Partition\s'
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

    It "reassigns letters that were swapped inside the exact simulated session" {
        $state = Read-SimulationState
        ($state.disks | Where-Object unique_id -eq "0x6589cfc000000001").drive_letter = "H"
        ($state.disks | Where-Object unique_id -eq "0x6589cfc000000002").drive_letter = "S"
        Save-SimulationState $state
        $expected = @(
            [pscustomobject]@{ name = "ssd"; disk_unique_id = "6589cfc000000001"; drive_letter = "S"; label = "GAMES_SSD" },
            [pscustomobject]@{ name = "hdd"; disk_unique_id = "6589cfc000000002"; drive_letter = "H"; label = "GAMES_HDD" }
        )

        Mount-ResetVolumes -ExpectedVolumes $expected `
            -Disks @($state.disks | Where-Object { $_.target_iqn -like "*:chimera" })

        $after = Read-SimulationState
        ($after.disks | Where-Object unique_id -eq "0x6589cfc000000001").drive_letter | Should -Be "S"
        ($after.disks | Where-Object unique_id -eq "0x6589cfc000000002").drive_letter | Should -Be "H"
    }
}

Describe "Windows drive-letter reconciliation" {
    BeforeEach {
        $script:SimulationStatePath = ""
        $script:ExpectedVolumes = @(
            [pscustomobject]@{ name = "ssd"; disk_unique_id = "aaa"; drive_letter = "E"; label = "GAMES_SSD" },
            [pscustomobject]@{ name = "hdd"; disk_unique_id = "bbb"; drive_letter = "F"; label = "GAMES_HDD" }
        )
        $script:SessionDisks = @(
            [pscustomobject]@{ Number = 10; UniqueId = "0xaaa"; IsOffline = $false; IsReadOnly = $false },
            [pscustomobject]@{ Number = 11; UniqueId = "0xbbb"; IsOffline = $false; IsReadOnly = $false }
        )
        $script:Partitions = @{
            10 = [pscustomobject]@{ DiskNumber = 10; PartitionNumber = 1; Type = "Basic"; DriveLetter = "E" }
            11 = [pscustomobject]@{ DiskNumber = 11; PartitionNumber = 1; Type = "Basic"; DriveLetter = "F" }
        }
        $script:Labels = @{ 10 = "GAMES_SSD"; 11 = "GAMES_HDD" }
        $script:ExternalLetters = @{}

        Mock Set-Disk { }
        Mock Get-Partition {
            return $script:Partitions[[int]$DiskNumber]
        }
        Mock Get-ResetPartitionVolumes {
            return [pscustomobject]@{
                FileSystemLabel = $script:Labels[[int]$Partition.DiskNumber]
            }
        }
        Mock Get-ResetDriveLetterVolumes {
            $letter = ([string]$DriveLetter).ToUpperInvariant()
            $sessionPartition = @($script:Partitions.Values | Where-Object {
                ([string]$_.DriveLetter).ToUpperInvariant() -eq $letter
            }) | Select-Object -First 1
            if ($null -ne $sessionPartition) {
                return [pscustomobject]@{ FileSystemLabel = $script:Labels[[int]$sessionPartition.DiskNumber] }
            }
            if ($script:ExternalLetters.ContainsKey($letter)) {
                return [pscustomobject]@{ FileSystemLabel = "EXTERNAL" }
            }
            return @()
        }
        Mock Get-ResetDriveLetterPartitions {
            $letter = ([string]$DriveLetter).ToUpperInvariant()
            $sessionPartition = @($script:Partitions.Values | Where-Object {
                ([string]$_.DriveLetter).ToUpperInvariant() -eq $letter
            }) | Select-Object -First 1
            if ($null -ne $sessionPartition) { return $sessionPartition }
            if ($script:ExternalLetters.ContainsKey($letter)) {
                return $script:ExternalLetters[$letter]
            }
            return @()
        }
        Mock Remove-PartitionAccessPath {
            $script:Partitions[[int]$DiskNumber].DriveLetter = $null
        }
        Mock Set-Partition {
            $script:Partitions[[int]$DiskNumber].DriveLetter = [string]$NewDriveLetter
        }
    }

    It "does not mutate letters that are already correct" {
        Mount-ResetVolumes -ExpectedVolumes $script:ExpectedVolumes -Disks $script:SessionDisks

        Should -Invoke Remove-PartitionAccessPath -Times 0 -Exactly
        Should -Invoke Set-Partition -Times 0 -Exactly
    }

    It "assigns configured letters when both are free" {
        $script:Partitions[10].DriveLetter = $null
        $script:Partitions[11].DriveLetter = $null

        Mount-ResetVolumes -ExpectedVolumes $script:ExpectedVolumes -Disks $script:SessionDisks

        $script:Partitions[10].DriveLetter | Should -Be "E"
        $script:Partitions[11].DriveLetter | Should -Be "F"
        Should -Invoke Remove-PartitionAccessPath -Times 0 -Exactly
        Should -Invoke Set-Partition -Times 2 -Exactly
    }

    It "breaks and resolves a complete E-F swap inside the proven session" {
        $script:Partitions[10].DriveLetter = "F"
        $script:Partitions[11].DriveLetter = "E"

        Mount-ResetVolumes -ExpectedVolumes $script:ExpectedVolumes -Disks $script:SessionDisks

        $script:Partitions[10].DriveLetter | Should -Be "E"
        $script:Partitions[11].DriveLetter | Should -Be "F"
        Should -Invoke Remove-PartitionAccessPath -Times 2 -Exactly -ParameterFilter {
            $AccessPath -match '^[EF]:$'
        }
        Should -Invoke Set-Partition -Times 2 -Exactly
    }

    It "rejects an external owner before changing any drive letter" {
        $script:Partitions[10].DriveLetter = $null
        $script:SessionDisks[0].IsOffline = $true
        $script:ExternalLetters["E"] = [pscustomobject]@{
            DiskNumber = 0
            PartitionNumber = 3
            DriveLetter = "E"
        }

        { Mount-ResetVolumes -ExpectedVolumes $script:ExpectedVolumes -Disks $script:SessionDisks } |
            Should -Throw "*outside the client session*"

        Should -Invoke Set-Disk -Times 0 -Exactly
        Should -Invoke Remove-PartitionAccessPath -Times 0 -Exactly
        Should -Invoke Set-Partition -Times 0 -Exactly
    }

    It "rejects an occupied letter whose partition owner cannot be proven" {
        $script:Partitions[10].DriveLetter = $null
        $script:SessionDisks[0].IsOffline = $true
        Mock Get-ResetDriveLetterVolumes {
            if ([string]$DriveLetter -eq "E") {
                return [pscustomobject]@{ FileSystemLabel = "OPTICAL" }
            }
            return @()
        }
        Mock Get-ResetDriveLetterPartitions { return @() }

        { Mount-ResetVolumes -ExpectedVolumes $script:ExpectedVolumes -Disks $script:SessionDisks } |
            Should -Throw "*unverified device*"

        Should -Invoke Set-Disk -Times 0 -Exactly
        Should -Invoke Remove-PartitionAccessPath -Times 0 -Exactly
        Should -Invoke Set-Partition -Times 0 -Exactly
    }

    It "rejects extra disks and a wrong NAA before bringing disks online" {
        $extra = @($script:SessionDisks) + [pscustomobject]@{
            Number = 12
            UniqueId = "ccc"
            IsOffline = $true
            IsReadOnly = $false
        }
        { Mount-ResetVolumes -ExpectedVolumes $script:ExpectedVolumes -Disks $extra } |
            Should -Throw "*Session exposed 3 disks*"

        $wrong = @(
            [pscustomobject]@{ Number = 10; UniqueId = "wrong"; IsOffline = $true; IsReadOnly = $false },
            $script:SessionDisks[1]
        )
        { Mount-ResetVolumes -ExpectedVolumes $script:ExpectedVolumes -Disks $wrong } |
            Should -Throw "*Expected exactly one session disk*"

        Should -Invoke Set-Disk -Times 0 -Exactly
        Should -Invoke Remove-PartitionAccessPath -Times 0 -Exactly
        Should -Invoke Set-Partition -Times 0 -Exactly
    }

    It "rejects a wrong non-empty label before changing drive letters" {
        $script:Labels[10] = "WRONG"

        { Mount-ResetVolumes -ExpectedVolumes $script:ExpectedVolumes -Disks $script:SessionDisks } |
            Should -Throw "*Volume label mismatch*"

        Should -Invoke Remove-PartitionAccessPath -Times 0 -Exactly
        Should -Invoke Set-Partition -Times 0 -Exactly
    }

    It "rejects read-only disks and multiple data partitions" {
        $script:SessionDisks[0].IsReadOnly = $true
        { Mount-ResetVolumes -ExpectedVolumes $script:ExpectedVolumes -Disks $script:SessionDisks } |
            Should -Throw "*unexpectedly read-only*"
        Should -Invoke Set-Disk -Times 0 -Exactly

        $script:SessionDisks[0].IsReadOnly = $false
        Mock Get-Partition {
            if ($DiskNumber -eq 10) {
                return @(
                    [pscustomobject]@{ DiskNumber = 10; PartitionNumber = 1; Type = "Basic"; DriveLetter = "E" },
                    [pscustomobject]@{ DiskNumber = 10; PartitionNumber = 2; Type = "Basic"; DriveLetter = $null }
                )
            }
            return $script:Partitions[[int]$DiskNumber]
        }
        { Mount-ResetVolumes -ExpectedVolumes $script:ExpectedVolumes -Disks $script:SessionDisks } |
            Should -Throw "*exactly one data partition*"
        Should -Invoke Remove-PartitionAccessPath -Times 0 -Exactly
        Should -Invoke Set-Partition -Times 0 -Exactly
    }

    It "retries transiently unavailable volume metadata" {
        $script:VolumeReads = 0
        Mock Start-Sleep { }
        Mock Get-ResetPartitionVolumes {
            $script:VolumeReads++
            if ($script:VolumeReads -eq 1) { return @() }
            return [pscustomobject]@{
                FileSystemLabel = $script:Labels[[int]$Partition.DiskNumber]
            }
        }

        Mount-ResetVolumes -ExpectedVolumes $script:ExpectedVolumes -Disks $script:SessionDisks

        Should -Invoke Start-Sleep -Times 1 -Exactly
    }

    It "retries transiently unavailable partition metadata" {
        $script:PartitionReads = 0
        Mock Start-Sleep { }
        Mock Get-Partition {
            $script:PartitionReads++
            if ($script:PartitionReads -eq 1) { return @() }
            return $script:Partitions[[int]$DiskNumber]
        }

        Mount-ResetVolumes -ExpectedVolumes $script:ExpectedVolumes -Disks $script:SessionDisks

        Should -Invoke Start-Sleep -Times 1 -Exactly
    }

    It "times out when volume metadata never becomes available" {
        Mock Get-ResetPartitionVolumes { return @() }
        $mappings = @(Get-ResetDiskMappings `
            -ExpectedVolumes $script:ExpectedVolumes -Disks $script:SessionDisks)

        { Wait-ResetVolumeAssignments -Mappings $mappings -TimeoutSeconds 0 } |
            Should -Throw "*Timed out waiting for partition and volume metadata*"
    }

    It "fails final verification when Windows did not keep the assigned letter" {
        $script:Partitions[10].DriveLetter = $null
        Mock Set-Partition { }

        { Mount-ResetVolumes -ExpectedVolumes $script:ExpectedVolumes -Disks $script:SessionDisks } |
            Should -Throw "*Drive letter verification failed*"
    }

    It "stops after a partial assignment failure without touching external disks" {
        $script:Partitions[10].DriveLetter = "F"
        $script:Partitions[11].DriveLetter = "E"
        Mock Set-Partition {
            if ($DiskNumber -eq 11) { throw "injected assignment failure" }
            $script:Partitions[[int]$DiskNumber].DriveLetter = [string]$NewDriveLetter
        }

        { Mount-ResetVolumes -ExpectedVolumes $script:ExpectedVolumes -Disks $script:SessionDisks } |
            Should -Throw "*injected assignment failure*"

        Should -Invoke Remove-PartitionAccessPath -Times 2 -Exactly
        Should -Invoke Set-Partition -Times 2 -Exactly
    }

    It "logs verified disks and every internal letter change" {
        $script:Partitions[10].DriveLetter = "F"
        $script:Partitions[11].DriveLetter = "E"
        Mock Write-ResetLog { }

        Mount-ResetVolumes -ExpectedVolumes $script:ExpectedVolumes `
            -Disks $script:SessionDisks -RequestId "request-letters"

        Should -Invoke Write-ResetLog -Times 2 -Exactly -ParameterFilter {
            $Event -eq "disk_verified" -and $RequestId -eq "request-letters"
        }
        Should -Invoke Write-ResetLog -Times 2 -Exactly -ParameterFilter {
            $Event -eq "drive_letter_removed" -and $RequestId -eq "request-letters"
        }
        Should -Invoke Write-ResetLog -Times 2 -Exactly -ParameterFilter {
            $Event -eq "drive_letter_assigned" -and $RequestId -eq "request-letters"
        }
    }
}

Describe "Client JSONL diagnostics" {
    BeforeEach {
        $script:SimulationStatePath = ""
        $script:LogPath = Join-Path $TestDrive "reset.jsonl"
    }

    It "writes structured disk details without a client token" {
        Write-ResetLog -Level "INFO" -Event "disk_verified" -RequestId "request-1" `
            -Message "verified" -LogPath $script:LogPath -Details @{
                disk_unique_id = "aaa"
                disk_number = 10
                current_drive_letter = "F"
                desired_drive_letter = "E"
            }

        $raw = Get-Content -LiteralPath $script:LogPath -Raw
        $record = $raw | ConvertFrom-Json
        $record.event | Should -Be "disk_verified"
        $record.disk_unique_id | Should -Be "aaa"
        $record.current_drive_letter | Should -Be "F"
        $raw | Should -Not -Match "Authorization|Bearer|test-token"
    }

    It "does not fail the client operation when local logging fails" {
        Mock Add-Content { throw "injected log failure" }

        { Write-ResetLog -Level "INFO" -Event "ready" -RequestId "request-1" `
            -LogPath $script:LogPath } | Should -Not -Throw
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

    It "records every successful stage without logging the token" {
        $state = Read-SimulationState
        ($state.disks | Where-Object unique_id -eq "wrong-naa").unique_id = "0x6589cfc000000001"
        Save-SimulationState $state
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

        $code = Invoke-ResetMain -BaseUrl "http://mock" `
            -ClientTokenPath $script:tokenPath -TimeoutSeconds 2

        $code | Should -Be 0
        $logPath = Join-Path $TestDrive "client.log.jsonl"
        $raw = Get-Content -LiteralPath $logPath -Raw
        $events = @(Get-Content -LiteralPath $logPath | ForEach-Object {
            ($_ | ConvertFrom-Json).event
        })
        foreach ($event in @(
            "start", "api_ready", "client_configuration_loaded", "prepared",
            "target_connected", "disk_verified", "ready"
        )) {
            $events | Should -Contain $event
        }
        $raw | Should -Not -Match "test-token|Authorization|Bearer"
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
