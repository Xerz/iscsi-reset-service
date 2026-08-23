BeforeAll {
    $script:ClientScriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) "Reset-And-Connect.ps1"
    . $script:ClientScriptPath -NoMain
    function Get-TestSingleDiskNumber {
        param([Parameter(Mandatory = $true)]$Value)
        $numbers = @($Value)
        if ($numbers.Count -ne 1) {
            throw "Expected exactly one mocked disk number"
        }
        return [int]$numbers[0]
    }
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
    if ($null -eq (Get-Command Get-IscsiTargetPortal -ErrorAction SilentlyContinue)) {
        Set-Item -Path "function:Get-IscsiTargetPortal" -Value { }
    }
    if ($null -eq (Get-Command New-IscsiTargetPortal -ErrorAction SilentlyContinue)) {
        Set-Item -Path "function:New-IscsiTargetPortal" -Value {
            param($TargetPortalAddress, $TargetPortalPortNumber)
        }
    }
    if ($null -eq (Get-Command Update-IscsiTargetPortal -ErrorAction SilentlyContinue)) {
        Set-Item -Path "function:Update-IscsiTargetPortal" -Value {
            param($TargetPortalAddress, $TargetPortalPortNumber)
        }
    }
    if ($null -eq (Get-Command Get-IscsiTarget -ErrorAction SilentlyContinue)) {
        Set-Item -Path "function:Get-IscsiTarget" -Value { }
    }
    if ($null -eq (Get-Command Connect-IscsiTarget -ErrorAction SilentlyContinue)) {
        Set-Item -Path "function:Connect-IscsiTarget" -Value {
            param(
                $NodeAddress,
                $TargetPortalAddress,
                $TargetPortalPortNumber,
                $IsPersistent,
                $IsMultipathEnabled,
                $AuthenticationType
            )
        }
    }
}

Describe "Reset-And-Connect safety helpers" {
    It "resolves the default EGS config beside the script and preserves an override" {
        Resolve-EgsSyncConfigPath -Path "" | Should -Be (
            Join-Path (Split-Path $script:ClientScriptPath -Parent) "egs-sync.json"
        )
        Resolve-EgsSyncConfigPath -Path "D:\custom\egs-sync.json" |
            Should -Be "D:\custom\egs-sync.json"
    }

    It "starts through a child PowerShell process without an explicit EGS config path" {
        $powerShell = (Get-Process -Id $PID).Path
        $output = @(& $powerShell -NoLogo -NoProfile -NonInteractive `
            -ExecutionPolicy Bypass -File $script:ClientScriptPath -NoMain 2>&1)
        $exitCode = $LASTEXITCODE

        $exitCode | Should -Be 0 -Because ($output -join [Environment]::NewLine)
    }

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
    It "normalizes the UInt32 array shape used by the real Windows Storage cmdlets" {
        Get-TestSingleDiskNumber -Value ([uint32[]]@(10)) | Should -Be 10
    }

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
            $number = Get-TestSingleDiskNumber -Value $DiskNumber
            return $script:Partitions[$number]
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
            $number = Get-TestSingleDiskNumber -Value $DiskNumber
            $script:Partitions[$number].DriveLetter = $null
        }
        Mock Set-Partition {
            $number = Get-TestSingleDiskNumber -Value $DiskNumber
            $script:Partitions[$number].DriveLetter = [string]$NewDriveLetter
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
            $number = Get-TestSingleDiskNumber -Value $DiskNumber
            if ($number -eq 10) {
                return @(
                    [pscustomobject]@{ DiskNumber = 10; PartitionNumber = 1; Type = "Basic"; DriveLetter = "E" },
                    [pscustomobject]@{ DiskNumber = 10; PartitionNumber = 2; Type = "Basic"; DriveLetter = $null }
                )
            }
            return $script:Partitions[$number]
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
            $number = Get-TestSingleDiskNumber -Value $DiskNumber
            return $script:Partitions[$number]
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
            $number = Get-TestSingleDiskNumber -Value $DiskNumber
            if ($number -eq 11) { throw "injected assignment failure" }
            $script:Partitions[$number].DriveLetter = [string]$NewDriveLetter
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

Describe "Windows iSCSI target discovery" {
    BeforeEach {
        $script:SimulationStatePath = ""
        $script:DiscoveryTarget = "iqn.2026-08.lab.games:chimera"
        $script:DiscoveryPortal = [pscustomobject]@{ address = "10.20.40.10"; port = 3260 }
        $script:DiscoveryQueries = 0
        $script:DiscoveryRefreshes = 0
        Mock Write-ResetLog { }
        Mock Update-IscsiTargetPortal { $script:DiscoveryRefreshes++ }
        Mock Get-IscsiTarget {
            $script:DiscoveryQueries++
            return [pscustomobject]@{ NodeAddress = $script:DiscoveryTarget }
        }
        Mock Start-Sleep { }
        Mock Connect-IscsiTarget { }
        Mock Set-Disk { }
    }

    It "returns immediately when the exact target is available" {
        $target = Wait-ResetTargetDiscovery -TargetIqn $script:DiscoveryTarget `
            -Portal $script:DiscoveryPortal -RequestId "request-1"

        $target.NodeAddress | Should -Be $script:DiscoveryTarget
        Should -Invoke Update-IscsiTargetPortal -Times 1 -Exactly -ParameterFilter {
            $TargetPortalAddress -eq "10.20.40.10" -and $TargetPortalPortNumber -eq 3260
        }
        Should -Invoke Get-IscsiTarget -Times 1 -Exactly
        Should -Invoke Start-Sleep -Times 0 -Exactly
        Should -Invoke Write-ResetLog -Times 1 -Exactly -ParameterFilter {
            $Event -eq "target_discovery_started"
        }
        Should -Invoke Write-ResetLog -Times 1 -Exactly -ParameterFilter {
            $Event -eq "target_discovered" -and $Details.attempts -eq 1
        }
    }

    It "refreshes once per second until the exact target appears" {
        Mock Get-IscsiTarget {
            $script:DiscoveryQueries++
            if ($script:DiscoveryQueries -lt 3) {
                return [pscustomobject]@{ NodeAddress = "iqn.2026-08.lab.games:other" }
            }
            return @(
                [pscustomobject]@{ NodeAddress = "iqn.2026-08.lab.games:other" },
                [pscustomobject]@{ NodeAddress = $script:DiscoveryTarget }
            )
        }

        $target = Wait-ResetTargetDiscovery -TargetIqn $script:DiscoveryTarget `
            -Portal $script:DiscoveryPortal -RequestId "request-2"

        $target.NodeAddress | Should -Be $script:DiscoveryTarget
        Should -Invoke Update-IscsiTargetPortal -Times 3 -Exactly
        Should -Invoke Get-IscsiTarget -Times 3 -Exactly
        Should -Invoke Start-Sleep -Times 2 -Exactly -ParameterFilter { $Seconds -eq 1 }
        Should -Invoke Write-ResetLog -Times 2 -Exactly
        Should -Invoke Write-ResetLog -Times 1 -Exactly -ParameterFilter {
            $Event -eq "target_discovered" -and $Details.attempts -eq 3
        }
    }

    It "continues after a transient portal refresh error" {
        Mock Update-IscsiTargetPortal {
            $script:DiscoveryRefreshes++
            if ($script:DiscoveryRefreshes -eq 1) { throw "transient refresh failure" }
        }
        Mock Get-IscsiTarget {
            $script:DiscoveryQueries++
            if ($script:DiscoveryQueries -lt 2) { return @() }
            return [pscustomobject]@{ NodeAddress = $script:DiscoveryTarget }
        }

        $target = Wait-ResetTargetDiscovery -TargetIqn $script:DiscoveryTarget `
            -Portal $script:DiscoveryPortal -RequestId "request-3"

        $target.NodeAddress | Should -Be $script:DiscoveryTarget
        Should -Invoke Update-IscsiTargetPortal -Times 2 -Exactly
        Should -Invoke Get-IscsiTarget -Times 2 -Exactly
        Should -Invoke Start-Sleep -Times 1 -Exactly
    }

    It "times out after exactly sixty checks without connecting or changing disks" {
        Mock Get-IscsiTarget {
            return [pscustomobject]@{ NodeAddress = "iqn.2026-08.lab.games:other" }
        }
        $failure = $null

        try {
            Wait-ResetTargetDiscovery -TargetIqn $script:DiscoveryTarget `
                -Portal $script:DiscoveryPortal -RequestId "request-4"
        } catch {
            $failure = $_
        }

        $failure | Should -Not -BeNullOrEmpty
        $failure.Exception.Data["Code"] | Should -Be "TARGET_DISCOVERY_TIMEOUT"
        Should -Invoke Update-IscsiTargetPortal -Times 60 -Exactly
        Should -Invoke Get-IscsiTarget -Times 60 -Exactly
        Should -Invoke Start-Sleep -Times 59 -Exactly -ParameterFilter { $Seconds -eq 1 }
        Should -Invoke Connect-IscsiTarget -Times 0 -Exactly
        Should -Invoke Set-Disk -Times 0 -Exactly
        Should -Invoke Write-ResetLog -Times 1 -Exactly -ParameterFilter {
            $Event -eq "target_discovery_started"
        }
    }
}

Describe "Startup flow failure handling" {
    BeforeEach {
        $script:SimulationStatePath = Join-Path $TestDrive "startup-state.json"
        $script:SimulationSourceIp = "10.20.40.101"
        $script:AllowHttpForSimulation = $true
        Remove-Item -LiteralPath (Join-Path $TestDrive "client.log.jsonl") -Force `
            -ErrorAction SilentlyContinue
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
        $syncConfig = Join-Path $TestDrive "egs-sync-disabled.json"
        @{ schema_version = 1; enabled = $false } | ConvertTo-Json |
            Set-Content -LiteralPath $syncConfig
        Mock Invoke-ClientEgsManifestSync { throw "disabled sync must not run" }

        $code = Invoke-ResetMain -BaseUrl "http://mock" `
            -ClientTokenPath $script:tokenPath -SyncConfigPath $syncConfig -TimeoutSeconds 2

        $code | Should -Be 0
        $logPath = Join-Path $TestDrive "client.log.jsonl"
        $raw = Get-Content -LiteralPath $logPath -Raw
        $events = @(Get-Content -LiteralPath $logPath | ForEach-Object {
            ($_ | ConvertFrom-Json).event
        })
        foreach ($event in @(
            "start", "api_ready", "client_configuration_loaded", "prepared",
            "target_discovery_started", "target_discovered", "target_connected",
            "disk_verified", "ready"
        )) {
            $events | Should -Contain $event
        }
        Should -Invoke Invoke-ResetRequest -Times 2 -Exactly
        Should -Invoke Invoke-ClientEgsManifestSync -Times 0 -Exactly
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

    It "logs discovery timeout and does not connect or mutate local disks" {
        Mock Invoke-ResetRequest {
            return [pscustomobject]@{
                target_iqn = "iqn.2026-08.lab.games:chimera"
                portal = [pscustomobject]@{ address = "10.20.40.10"; port = 3260 }
            }
        }
        Mock Invoke-PrepareWithRetry {
            return [pscustomobject]@{
                target_iqn = "iqn.2026-08.lab.games:chimera"
                portal = [pscustomobject]@{ address = "10.20.40.10"; port = 3260 }
                volumes = @(
                    [pscustomobject]@{ name = "ssd"; disk_unique_id = "aaa"; drive_letter = "S"; label = "GAMES_SSD" }
                )
            }
        }
        Mock Wait-ResetTargetDiscovery {
            throw (New-ApiException -StatusCode 0 -Code "TARGET_DISCOVERY_TIMEOUT" `
                -Message "target was not discovered")
        }
        Mock Connect-ResetTarget { }
        Mock Mount-ResetVolumes { }

        $code = Invoke-ResetMain -BaseUrl "http://mock" `
            -ClientTokenPath $script:tokenPath -TimeoutSeconds 2

        $code | Should -Be 40
        Should -Invoke Wait-ResetTargetDiscovery -Times 1 -Exactly
        Should -Invoke Connect-ResetTarget -Times 0 -Exactly
        Should -Invoke Mount-ResetVolumes -Times 0 -Exactly
        @((Read-SimulationState).sessions).Count | Should -Be 0
        $logPath = Join-Path $TestDrive "client.log.jsonl"
        $raw = Get-Content -LiteralPath $logPath -Raw
        $events = @(Get-Content -LiteralPath $logPath | ForEach-Object {
            ($_ | ConvertFrom-Json).event
        })
        $events | Should -Contain "TARGET_DISCOVERY_TIMEOUT"
        $raw | Should -Not -Match "test-token|Authorization|Bearer"
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

    It "disconnects the newly-created session when enabled EGS sync fails" {
        $state = Read-SimulationState
        ($state.disks | Where-Object unique_id -eq "wrong-naa").unique_id = "0x6589cfc000000001"
        Save-SimulationState $state
        $syncConfig = Join-Path $TestDrive "egs-sync.json"
        @{ schema_version = 1; enabled = $true } | ConvertTo-Json | Set-Content $syncConfig
        Mock Wait-ResetApi { return [pscustomobject]@{ config_revision = "rev-1" } }
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
        Mock Invoke-ClientEgsManifestSync { throw "injected EGS metadata failure" }

        $code = Invoke-ResetMain -BaseUrl "http://mock" -ClientTokenPath $script:tokenPath `
            -SyncConfigPath $syncConfig -TimeoutSeconds 2

        $code | Should -Be 40
        @((Read-SimulationState).sessions).Count | Should -Be 0
        $events = @(Get-Content -LiteralPath (Join-Path $TestDrive "client.log.jsonl") |
            ForEach-Object { ($_ | ConvertFrom-Json).event })
        $events | Should -Contain "CLIENT_ERROR"
        $events | Should -Not -Contain "ready"
    }

    It "logs registration takeover before manifest sync readiness" {
        $state = Read-SimulationState
        ($state.disks | Where-Object unique_id -eq "wrong-naa").unique_id =
            "0x6589cfc000000001"
        Save-SimulationState $state
        $syncConfig = Join-Path $TestDrive "egs-sync.json"
        @{ schema_version = 1; enabled = $true } | ConvertTo-Json | Set-Content $syncConfig
        Mock Wait-ResetApi { return [pscustomobject]@{ config_revision = "rev-1" } }
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
        Mock Invoke-ClientEgsManifestSync {
            return [pscustomobject]@{
                ManifestCount = 2
                AdoptedAppCount = 1
                DisplacedManifestCount = 1
                LauncherEntryRemovalCount = 0
                LauncherEntryImportCount = 2
                LauncherFallbackAppCount = 0
                IncompleteWarningCount = 0
            }
        }

        $code = Invoke-ResetMain -BaseUrl "http://mock" -ClientTokenPath $script:tokenPath `
            -SyncConfigPath $syncConfig -TimeoutSeconds 2

        $code | Should -Be 0
        $logPath = Join-Path $TestDrive "client.log.jsonl"
        $records = @(Get-Content -LiteralPath $logPath | ForEach-Object {
            $_ | ConvertFrom-Json
        })
        $events = @($records.event)
        [Array]::IndexOf($events, "egs_registration_takeover") |
            Should -BeLessThan ([Array]::IndexOf($events, "egs_launcher_registration_sync"))
        [Array]::IndexOf($events, "egs_launcher_registration_sync") |
            Should -BeLessThan ([Array]::IndexOf($events, "egs_manifest_sync_ready"))
        [Array]::IndexOf($events, "egs_manifest_sync_ready") |
            Should -BeLessThan ([Array]::IndexOf($events, "ready"))
        $takeover = $records | Where-Object event -eq "egs_registration_takeover"
        $takeover.adopted_app_count | Should -Be 1
        $takeover.displaced_manifest_count | Should -Be 1
        $registration = $records | Where-Object event -eq "egs_launcher_registration_sync"
        $registration.imported_registration_count | Should -Be 2
        $registration.item_only_fallback_count | Should -Be 0
        (Get-Content -LiteralPath $logPath -Raw) |
            Should -Not -Match "BaseURLs|publisher.invalid|client.invalid"
    }

    It "logs aggressive ProgramData readiness before manifest readiness" {
        $state = Read-SimulationState
        ($state.disks | Where-Object unique_id -eq "wrong-naa").unique_id =
            "0x6589cfc000000001"
        Save-SimulationState $state
        $syncConfig = Join-Path $TestDrive "egs-sync-aggressive.json"
        @{ schema_version = 2; mode = "aggressive" } | ConvertTo-Json |
            Set-Content $syncConfig
        Mock Wait-ResetApi { return [pscustomobject]@{ config_revision = "rev-1" } }
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
        Mock Invoke-ClientEgsManifestSync { throw "managed mode must not run" }
        Mock Invoke-ClientEgsAggressiveSync {
            return [pscustomobject]@{
                ManifestCount = 3
                FileCount = 42
                TotalBytes = 123456
                Changed = $true
                IncompleteWarningCount = 0
            }
        }

        $code = Invoke-ResetMain -BaseUrl "http://mock" `
            -ClientTokenPath $script:tokenPath -SyncConfigPath $syncConfig -TimeoutSeconds 2

        $code | Should -Be 0
        $records = @(Get-Content -LiteralPath (Join-Path $TestDrive "client.log.jsonl") |
            ForEach-Object { $_ | ConvertFrom-Json })
        $events = @($records.event)
        [Array]::IndexOf($events, "egs_programdata_sync_ready") |
            Should -BeLessThan ([Array]::IndexOf($events, "egs_manifest_sync_ready"))
        [Array]::IndexOf($events, "egs_manifest_sync_ready") |
            Should -BeLessThan ([Array]::IndexOf($events, "ready"))
        $programData = $records | Where-Object event -eq "egs_programdata_sync_ready"
        $programData.file_count | Should -Be 42
        $programData.game_count | Should -Be 3
        $programData.total_bytes | Should -Be 123456
        Should -Invoke Invoke-ClientEgsAggressiveSync -Times 1 -Exactly
        Should -Invoke Invoke-ClientEgsManifestSync -Times 0 -Exactly
    }
}

Describe "Epic Games client manifest validation and transaction" {
    BeforeAll {
      function New-ClientTestItemBytes {
        param(
            [Parameter(Mandatory = $true)][string]$AppName,
            [Parameter(Mandatory = $true)][string]$Guid,
            [Parameter(Mandatory = $true)][string]$InstallLocation,
            [string]$Version = "build-1",
            [string[]]$InstallTags = @("default"),
            [string[]]$BaseURLs = @("https://publisher.invalid/egs"),
            [switch]$Utf8Bom
        )
        $item = [ordered]@{
            AppName = $AppName
            AppVersionString = $Version
            InstallationGuid = $Guid
            InstallLocation = $InstallLocation
            ManifestLocation = (Join-Path $InstallLocation ".egstore")
            StagingLocation = (Join-Path $InstallLocation ".egstore/bps")
            InstallTags = $InstallTags
            BaseURLs = $BaseURLs
            LaunchExecutable = "$AppName.exe"
        }
        $encoding = New-Object Text.UTF8Encoding($Utf8Bom.IsPresent)
        return [byte[]]@($encoding.GetPreamble()) + $encoding.GetBytes(
            ($item | ConvertTo-Json -Depth 5)
        )
      }

      function New-ClientTestDesired {
        param(
            [Parameter(Mandatory = $true)][string]$AppName,
            [Parameter(Mandatory = $true)][string]$Guid,
            [Parameter(Mandatory = $true)][string]$InstallLocation,
            [string]$Version = "build-1",
            [string[]]$InstallTags = @("default"),
            [string[]]$BaseURLs = @("https://publisher.invalid/egs"),
            [switch]$WithLauncherRegistration
        )
        $bytes = New-ClientTestItemBytes -AppName $AppName -Guid $Guid `
            -InstallLocation $InstallLocation -Version $Version -InstallTags $InstallTags `
            -BaseURLs $BaseURLs
        $registration = if ($WithLauncherRegistration) {
            [pscustomobject]@{
                InstallLocation = (ConvertTo-EgsCanonicalPath $InstallLocation)
                NamespaceId = "namespace-$AppName"
                ItemId = "item-$AppName"
                ArtifactId = "artifact-$AppName"
                AppVersion = $Version
                AppName = $AppName
            }
        } else { $null }
        return [pscustomobject]@{
            AppName = $AppName
            AppVersion = $Version
            InstallationGuid = $Guid
            InstallLocation = (ConvertTo-EgsCanonicalPath $InstallLocation)
            Sha256 = Get-EgsSha256Hex $bytes
            Bytes = $bytes
            TargetFileName = "$Guid.item"
            LauncherRegistration = $registration
            StateWarnings = @()
        }
      }

      function New-ClientTestBundle {
        param(
            [Parameter(Mandatory = $true)][string]$VolumeRoot,
            [Parameter(Mandatory = $true)][string]$VolumeName,
            [Parameter(Mandatory = $true)][string]$ConfigRevision,
            [Parameter(Mandatory = $true)][string]$AppName,
            [Parameter(Mandatory = $true)][string]$Guid,
            [string[]]$InstallTags = @("default"),
            [switch]$Utf8Bom,
            [switch]$OmitComponent,
            [switch]$WithLauncherRegistration
        )
        $installLocation = Join-Path $VolumeRoot $AppName
        $egstore = Join-Path $installLocation ".egstore"
        New-Item -ItemType Directory -Path $egstore -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $installLocation "$AppName.exe") -Value "exe"
        [IO.File]::WriteAllBytes((Join-Path $egstore "$Guid.manifest"), [byte[]](1, 2, 3))
        if (-not $OmitComponent) {
            @{ AppName = $AppName } | ConvertTo-Json | Set-Content `
                -LiteralPath (Join-Path $egstore "$Guid.mancpn")
        }
        $bytes = New-ClientTestItemBytes -AppName $AppName -Guid $Guid `
            -InstallLocation $installLocation -InstallTags $InstallTags -Utf8Bom:$Utf8Bom
        $bundle = [ordered]@{
            schema_version = 2
            config_revision = $ConfigRevision
            volume_name = $VolumeName
            manifests = @([ordered]@{
                app_name = $AppName
                installation_guid = $Guid
                sha256 = Get-EgsSha256Hex $bytes
                payload_base64 = [Convert]::ToBase64String($bytes)
                binary_manifest_sha256 = Get-EgsSha256Hex (
                    [IO.File]::ReadAllBytes((Join-Path $egstore "$Guid.manifest"))
                )
                mancpn_sha256 = if ($OmitComponent) { $null } else {
                    Get-EgsSha256Hex (
                        [IO.File]::ReadAllBytes((Join-Path $egstore "$Guid.mancpn"))
                    )
                }
                launcher_registration = if ($WithLauncherRegistration) {
                    [ordered]@{
                        install_location = $installLocation
                        namespace_id = "namespace-$AppName"
                        item_id = "item-$AppName"
                        artifact_id = "artifact-$AppName"
                        app_version = "build-1"
                        app_name = $AppName
                    }
                } else { $null }
                state_warnings = @()
            })
        }
        $bundlePath = Join-Path $VolumeRoot "egs-manifests.v2.json"
        $bundle | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $bundlePath
        return $bundlePath
      }

      function Set-ClientTestLauncherInstalled {
        param(
            [Parameter(Mandatory = $true)][string]$Path,
            [Parameter(Mandatory = $true)]$InstallationList,
            [string]$UnknownValue = "preserve-me"
        )
        [ordered]@{
            InstallationList = @($InstallationList)
            UnknownTopLevel = $UnknownValue
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path
      }
    }

    BeforeEach {
        $script:EgsClientRoot = Join-Path $TestDrive "client-volume"
        $script:EgsManifestDirectory = Join-Path $TestDrive "ProgramData-Manifests"
        $script:EgsStatePath = Join-Path $TestDrive "egs-managed-apps.v1.json"
        $script:EgsTransactionPath = Join-Path $TestDrive "egs-sync-transaction"
        $script:EgsLauncherInstalledPath = Join-Path $TestDrive "LauncherInstalled.dat"
        $script:EgsArchiveDirectory = Join-Path $TestDrive "egs-displaced-registrations"
        Remove-Item -LiteralPath $script:EgsClientRoot -Recurse -Force `
            -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $script:EgsManifestDirectory -Recurse -Force `
            -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $script:EgsStatePath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $script:EgsTransactionPath -Recurse -Force `
            -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $script:EgsLauncherInstalledPath -Force `
            -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $script:EgsArchiveDirectory -Recurse -Force `
            -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Path $script:EgsClientRoot -Force | Out-Null
        New-Item -ItemType Directory -Path $script:EgsManifestDirectory -Force | Out-Null
    }

    It "validates a BOM-prefixed Fortnite manifest and accepts an empty bundle" {
        $fortniteId = "6CBCB32C02D40E72A7D7C61F8AB8A4A"
        $bundlePath = New-ClientTestBundle -VolumeRoot $script:EgsClientRoot `
            -VolumeName "ssd" -ConfigRevision "rev-1" -AppName "Fortnite" `
            -Guid $fortniteId -InstallTags @("chunk0", "chunk10", "chunk10optional") `
            -Utf8Bom -OmitComponent -WithLauncherRegistration

        $items = @(Read-ClientEgsBundle -Path $bundlePath -ConfigRevision "rev-1" `
            -VolumeName "ssd" -VolumeRoot $script:EgsClientRoot)
        $items.Count | Should -Be 1
        $items[0].InstallationGuid | Should -Be $fortniteId
        [BitConverter]::ToString($items[0].Bytes[0..2]) | Should -Be "EF-BB-BF"
        $payload = ConvertFrom-EgsJsonBytes -Bytes $items[0].Bytes
        @($payload.InstallTags) -join "," | Should -Be "chunk0,chunk10,chunk10optional"
        $items[0].LauncherRegistration.ArtifactId | Should -Be "artifact-Fortnite"

        $emptyPath = Join-Path $script:EgsClientRoot "empty.json"
        @{
            schema_version = 2
            config_revision = "rev-1"
            volume_name = "ssd"
            manifests = @()
        } | ConvertTo-Json | Set-Content -LiteralPath $emptyPath
        @(Read-ClientEgsBundle -Path $emptyPath -ConfigRevision "rev-1" `
            -VolumeName "ssd" -VolumeRoot $script:EgsClientRoot).Count | Should -Be 0
    }

    It "rejects legacy v1 bundles and mismatched .egstore hashes" {
        $legacyPath = Join-Path $script:EgsClientRoot "legacy.json"
        @{
            schema_version = 1
            config_revision = "rev-1"
            volume_name = "ssd"
            manifests = @()
        } | ConvertTo-Json | Set-Content -LiteralPath $legacyPath
        {
            Read-ClientEgsBundle -Path $legacyPath -ConfigRevision "rev-1" `
                -VolumeName "ssd" -VolumeRoot $script:EgsClientRoot
        } | Should -Throw "*does not match*"

        $bundlePath = New-ClientTestBundle -VolumeRoot $script:EgsClientRoot `
            -VolumeName "ssd" -ConfigRevision "rev-1" -AppName "Fortnite" `
            -Guid "52525252525252525252525252525252"
        $bundle = Get-Content -LiteralPath $bundlePath -Raw | ConvertFrom-Json
        $bundle.manifests[0].binary_manifest_sha256 = "0" * 64
        $bundle | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $bundlePath
        {
            Read-ClientEgsBundle -Path $bundlePath -ConfigRevision "rev-1" `
                -VolumeName "ssd" -VolumeRoot $script:EgsClientRoot
        } | Should -Throw "*binary manifest hash*"
    }

    It "preserves and verifies incomplete installation warnings" {
        $guid = "53535353535353535353535353535353"
        $bundlePath = New-ClientTestBundle -VolumeRoot $script:EgsClientRoot `
            -VolumeName "ssd" -ConfigRevision "rev-1" -AppName "Fortnite" -Guid $guid
        $bundle = Get-Content -LiteralPath $bundlePath -Raw | ConvertFrom-Json
        $itemBytes = [Convert]::FromBase64String(
            [string]$bundle.manifests[0].payload_base64
        )
        $item = ConvertFrom-EgsJsonBytes -Bytes $itemBytes
        $item | Add-Member -NotePropertyName bIsIncompleteInstall -NotePropertyValue $true
        $item | Add-Member -NotePropertyName bNeedsValidation -NotePropertyValue $true
        $itemBytes = [Text.Encoding]::UTF8.GetBytes(($item | ConvertTo-Json -Depth 8))
        $bundle.manifests[0].sha256 = Get-EgsSha256Hex $itemBytes
        $bundle.manifests[0].payload_base64 = [Convert]::ToBase64String($itemBytes)
        $bundle.manifests[0].state_warnings = @(
            "item_incomplete", "item_needs_validation", "bps_nonempty", "pending_nonempty"
        )
        $egstore = Join-Path (Join-Path $script:EgsClientRoot "Fortnite") ".egstore"
        New-Item -ItemType Directory -Path (Join-Path $egstore "bps") -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $egstore "Pending") -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $egstore "bps/staging.dat") -Value "pending"
        Set-Content -LiteralPath (Join-Path $egstore "Pending/chunk.dat") -Value "pending"
        $bundle | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $bundlePath

        $result = @(Read-ClientEgsBundle -Path $bundlePath -ConfigRevision "rev-1" `
            -VolumeName "ssd" -VolumeRoot $script:EgsClientRoot)
        @($result[0].StateWarnings).Count | Should -Be 4

        $bundle.manifests[0].state_warnings = @("item_incomplete")
        $bundle | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $bundlePath
        {
            Read-ClientEgsBundle -Path $bundlePath -ConfigRevision "rev-1" `
                -VolumeName "ssd" -VolumeRoot $script:EgsClientRoot
        } | Should -Throw "*state warnings*"
    }

    It "rejects bad revision, hash, installation identifier, and volume path" {
        $bundlePath = New-ClientTestBundle -VolumeRoot $script:EgsClientRoot `
            -VolumeName "ssd" -ConfigRevision "rev-1" -AppName "Fortnite" `
            -Guid "55555555555555555555555555555555"
        {
            Read-ClientEgsBundle -Path $bundlePath -ConfigRevision "rev-2" `
                -VolumeName "ssd" -VolumeRoot $script:EgsClientRoot
        } | Should -Throw "*current config revision*"

        $bundle = Get-Content -LiteralPath $bundlePath -Raw | ConvertFrom-Json
        $bundle.config_revision = "rev-1"
        $bundle.manifests[0].sha256 = "0" * 64
        $bundle | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $bundlePath
        {
            Read-ClientEgsBundle -Path $bundlePath -ConfigRevision "rev-1" `
                -VolumeName "ssd" -VolumeRoot $script:EgsClientRoot
        } | Should -Throw "*hash verification failed*"

        $invalidIdPath = New-ClientTestBundle -VolumeRoot $script:EgsClientRoot `
            -VolumeName "ssd" -ConfigRevision "rev-1" -AppName "Fortnite" `
            -Guid "55555555555555555555555555555555"
        $invalidIdBundle = Get-Content -LiteralPath $invalidIdPath -Raw | ConvertFrom-Json
        $invalidItemBytes = [Convert]::FromBase64String(
            [string]$invalidIdBundle.manifests[0].payload_base64
        )
        $invalidItem = [Text.Encoding]::UTF8.GetString($invalidItemBytes) | ConvertFrom-Json
        $invalidItem.InstallationGuid = "unsafe-id"
        $invalidItemBytes = [Text.Encoding]::UTF8.GetBytes(
            ($invalidItem | ConvertTo-Json -Depth 8)
        )
        $invalidIdBundle.manifests[0].installation_guid = "unsafe-id"
        $invalidIdBundle.manifests[0].sha256 = Get-EgsSha256Hex $invalidItemBytes
        $invalidIdBundle.manifests[0].payload_base64 = [Convert]::ToBase64String(
            $invalidItemBytes
        )
        $invalidIdBundle | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $invalidIdPath
        {
            Read-ClientEgsBundle -Path $invalidIdPath -ConfigRevision "rev-1" `
                -VolumeName "ssd" -VolumeRoot $script:EgsClientRoot
        } | Should -Throw "*invalid Epic installation identifier*"

        $otherRoot = Join-Path $TestDrive "other-volume"
        New-Item -ItemType Directory -Path $otherRoot -Force | Out-Null
        $otherBundle = New-ClientTestBundle -VolumeRoot $otherRoot `
            -VolumeName "ssd" -ConfigRevision "rev-1" -AppName "GTA5" `
            -Guid "66666666666666666666666666666666"
        {
            Read-ClientEgsBundle -Path $otherBundle -ConfigRevision "rev-1" `
                -VolumeName "ssd" -VolumeRoot $script:EgsClientRoot
        } | Should -Throw "*does not belong*"
    }

    It "preserves unrelated local games and removes only stale managed manifests" {
        $fortniteGuid = "77777777777777777777777777777777"
        $oldGuid = "88888888888888888888888888888888"
        $localGuid = "99999999999999999999999999999999"
        $fortniteLocation = Join-Path $script:EgsClientRoot "Fortnite"
        $oldLocation = Join-Path $script:EgsClientRoot "OldGame"
        $localLocation = Join-Path $TestDrive "local-game"
        $oldFortnite = New-ClientTestItemBytes -AppName "Fortnite" -Guid $fortniteGuid `
            -InstallLocation $fortniteLocation -Version "old"
        $newFortnite = New-ClientTestDesired -AppName "Fortnite" -Guid $fortniteGuid `
            -InstallLocation $fortniteLocation -Version "new" `
            -InstallTags @("chunk0", "chunk10")
        $oldGame = New-ClientTestItemBytes -AppName "OldGame" -Guid $oldGuid `
            -InstallLocation $oldLocation
        $localGame = New-ClientTestItemBytes -AppName "LocalGame" -Guid $localGuid `
            -InstallLocation $localLocation -Utf8Bom
        [IO.File]::WriteAllBytes((Join-Path $script:EgsManifestDirectory "$fortniteGuid.item"), $oldFortnite)
        [IO.File]::WriteAllBytes((Join-Path $script:EgsManifestDirectory "$oldGuid.item"), $oldGame)
        [IO.File]::WriteAllBytes((Join-Path $script:EgsManifestDirectory "$localGuid.item"), $localGame)
        $localHash = Get-EgsSha256Hex $localGame
        @{
            schema_version = 1
            manifests = @(
                @{ app_name = "Fortnite"; installation_guid = $fortniteGuid; install_location = $fortniteLocation; sha256 = (Get-EgsSha256Hex $oldFortnite) },
                @{ app_name = "OldGame"; installation_guid = $oldGuid; install_location = $oldLocation; sha256 = (Get-EgsSha256Hex $oldGame) }
            )
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:EgsStatePath
        Mock Assert-EgsLauncherStopped { }

        $existing = @(Read-ExistingEgsManifests -ManifestDirectory $script:EgsManifestDirectory)
        $managed = Read-ClientEgsManagedState -Path $script:EgsStatePath
        $plan = New-ClientEgsSyncPlan -Desired @($newFortnite) `
            -Existing $existing -ManagedState $managed
        $launcherPlan = New-ClientEgsLauncherInstalledPlan `
            -Path $script:EgsLauncherInstalledPath -Desired @($newFortnite)
        Invoke-ClientEgsTransaction -Plan $plan `
            -ManifestDirectory $script:EgsManifestDirectory -StatePath $script:EgsStatePath `
            -TransactionPath $script:EgsTransactionPath `
            -ArchiveDirectory $script:EgsArchiveDirectory `
            -LauncherInstalledPlan $launcherPlan

        Get-EgsSha256Hex ([IO.File]::ReadAllBytes(
            (Join-Path $script:EgsManifestDirectory "$fortniteGuid.item")
        )) | Should -Be $newFortnite.Sha256
        Test-Path -LiteralPath (Join-Path $script:EgsManifestDirectory "$oldGuid.item") | Should -BeFalse
        Get-EgsSha256Hex ([IO.File]::ReadAllBytes(
            (Join-Path $script:EgsManifestDirectory "$localGuid.item")
        )) | Should -Be $localHash
        @((Read-ClientEgsManagedState -Path $script:EgsStatePath).manifests).Count |
            Should -Be 1
    }

    It "rolls back after the first manifest mutation and succeeds on retry" {
        $fortniteGuid = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        $gtaGuid = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        $fortniteLocation = Join-Path $script:EgsClientRoot "Fortnite"
        $gtaLocation = Join-Path $script:EgsClientRoot "GTA5"
        $oldFortnite = New-ClientTestItemBytes -AppName "Fortnite" -Guid $fortniteGuid `
            -InstallLocation $fortniteLocation -Version "old"
        $newFortnite = New-ClientTestDesired -AppName "Fortnite" -Guid $fortniteGuid `
            -InstallLocation $fortniteLocation -Version "new"
        $gta = New-ClientTestDesired -AppName "GTA5" -Guid $gtaGuid `
            -InstallLocation $gtaLocation
        $fortnitePath = Join-Path $script:EgsManifestDirectory "$fortniteGuid.item"
        [IO.File]::WriteAllBytes($fortnitePath, $oldFortnite)
        $oldHash = Get-EgsSha256Hex $oldFortnite
        @{
            schema_version = 1
            manifests = @(@{
                app_name = "Fortnite"
                installation_guid = $fortniteGuid
                install_location = $fortniteLocation
                sha256 = $oldHash
            })
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:EgsStatePath
        $stateHash = Get-EgsSha256Hex ([IO.File]::ReadAllBytes($script:EgsStatePath))
        Mock Assert-EgsLauncherStopped { }
        Mock Stop-EgsLauncherProcesses { }
        $script:EgsWriteCalls = 0
        $script:InjectEgsWriteFailure = $true
        Mock Write-EgsBytesAtomic {
            $script:EgsWriteCalls++
            if ($script:InjectEgsWriteFailure -and $script:EgsWriteCalls -eq 2) {
                throw "injected after first mutation"
            }
            $parent = Split-Path $Path -Parent
            if (-not (Test-Path -LiteralPath $parent)) {
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
            }
            [IO.File]::WriteAllBytes($Path, $Bytes)
        }

        $existing = @(Read-ExistingEgsManifests -ManifestDirectory $script:EgsManifestDirectory)
        $managed = Read-ClientEgsManagedState -Path $script:EgsStatePath
        $plan = New-ClientEgsSyncPlan -Desired @($newFortnite, $gta) `
            -Existing $existing -ManagedState $managed
        $launcherPlan = New-ClientEgsLauncherInstalledPlan `
            -Path $script:EgsLauncherInstalledPath -Desired @($newFortnite, $gta)
        {
            Invoke-ClientEgsTransaction -Plan $plan `
                -ManifestDirectory $script:EgsManifestDirectory -StatePath $script:EgsStatePath `
                -TransactionPath $script:EgsTransactionPath `
                -ArchiveDirectory $script:EgsArchiveDirectory `
                -LauncherInstalledPlan $launcherPlan
        } | Should -Throw "*injected after first mutation*"

        Get-EgsSha256Hex ([IO.File]::ReadAllBytes($fortnitePath)) | Should -Be $oldHash
        Test-Path -LiteralPath (Join-Path $script:EgsManifestDirectory "$gtaGuid.item") | Should -BeFalse
        Get-EgsSha256Hex ([IO.File]::ReadAllBytes($script:EgsStatePath)) | Should -Be $stateHash
        Test-Path -LiteralPath $script:EgsTransactionPath | Should -BeFalse

        $script:InjectEgsWriteFailure = $false
        Invoke-ClientEgsTransaction -Plan $plan `
            -ManifestDirectory $script:EgsManifestDirectory -StatePath $script:EgsStatePath `
            -TransactionPath $script:EgsTransactionPath `
            -ArchiveDirectory $script:EgsArchiveDirectory `
            -LauncherInstalledPlan $launcherPlan

        Get-EgsSha256Hex ([IO.File]::ReadAllBytes($fortnitePath)) |
            Should -Be $newFortnite.Sha256
        Test-Path -LiteralPath (Join-Path $script:EgsManifestDirectory "$gtaGuid.item") |
            Should -BeTrue
        @((Read-ClientEgsManagedState -Path $script:EgsStatePath).manifests).Count |
            Should -Be 2
    }

    It "creates LauncherInstalled.dat for three registrations on a clean EGS client" {
        $desired = @(
            New-ClientTestDesired -AppName "GTA5" `
                -Guid "70707070707070707070707070707070" `
                -InstallLocation (Join-Path $script:EgsClientRoot "GTA5") `
                -WithLauncherRegistration
            New-ClientTestDesired -AppName "Fortnite" `
                -Guid "80808080808080808080808080808080" `
                -InstallLocation (Join-Path $script:EgsClientRoot "Fortnite") `
                -WithLauncherRegistration
            New-ClientTestDesired -AppName "GTA5Enhanced" `
                -Guid "90909090909090909090909090909090" `
                -InstallLocation (Join-Path $script:EgsClientRoot "GTA5Enhanced") `
                -WithLauncherRegistration
        )
        $plan = New-ClientEgsSyncPlan -Desired $desired -Existing @() `
            -ManagedState ([pscustomobject]@{ schema_version = 1; manifests = @() })
        $launcherPlan = New-ClientEgsLauncherInstalledPlan `
            -Path $script:EgsLauncherInstalledPath -Desired $desired
        Mock Assert-EgsLauncherStopped { }

        $launcherPlan.RequiresWrite | Should -BeTrue
        $launcherPlan.SourceExisted | Should -BeFalse
        $launcherPlan.ImportedEntryCount | Should -Be 3
        Invoke-ClientEgsTransaction -Plan $plan `
            -ManifestDirectory $script:EgsManifestDirectory -StatePath $script:EgsStatePath `
            -TransactionPath $script:EgsTransactionPath `
            -ArchiveDirectory $script:EgsArchiveDirectory `
            -LauncherInstalledPlan $launcherPlan

        $launcher = Get-Content -LiteralPath $script:EgsLauncherInstalledPath -Raw |
            ConvertFrom-Json
        @($launcher.InstallationList).Count | Should -Be 3
        @($launcher.InstallationList.AppName | Sort-Object) | Should -Be @(
            "Fortnite", "GTA5", "GTA5Enhanced"
        )
        foreach ($entry in @($launcher.InstallationList)) {
            @($entry.PSObject.Properties.Name | Sort-Object) | Should -Be @(
                "AppName", "AppVersion", "ArtifactId", "InstallLocation", "ItemId",
                "NamespaceId"
            )
        }
        Test-Path -LiteralPath $script:EgsTransactionPath | Should -BeFalse
    }

    It "rolls back a newly created LauncherInstalled.dat after a later mutation fails" {
        $desired = New-ClientTestDesired -AppName "Fortnite" `
            -Guid "91919191919191919191919191919191" `
            -InstallLocation (Join-Path $script:EgsClientRoot "Fortnite") `
            -WithLauncherRegistration
        $plan = New-ClientEgsSyncPlan -Desired @($desired) -Existing @() `
            -ManagedState ([pscustomobject]@{ schema_version = 1; manifests = @() })
        $launcherPlan = New-ClientEgsLauncherInstalledPlan `
            -Path $script:EgsLauncherInstalledPath -Desired @($desired)
        Mock Assert-EgsLauncherStopped { }
        Mock Stop-EgsLauncherProcesses { }
        Mock Write-ClientEgsManagedState { throw "injected after new launcher registration" }

        {
            Invoke-ClientEgsTransaction -Plan $plan `
                -ManifestDirectory $script:EgsManifestDirectory `
                -StatePath $script:EgsStatePath `
                -TransactionPath $script:EgsTransactionPath `
                -ArchiveDirectory $script:EgsArchiveDirectory `
                -LauncherInstalledPlan $launcherPlan
        } | Should -Throw "*after new launcher registration*"

        Test-Path -LiteralPath $script:EgsLauncherInstalledPath | Should -BeFalse
        Test-Path -LiteralPath $script:EgsStatePath | Should -BeFalse
        Test-Path -LiteralPath $script:EgsTransactionPath | Should -BeFalse
    }

    It "adopts an unmanaged Fortnite manifest that differs only in BaseURLs" {
        $guid = "cccccccccccccccccccccccccccccccc"
        $networkLocation = Join-Path $script:EgsClientRoot "Fortnite"
        $desired = New-ClientTestDesired -AppName "Fortnite" -Guid $guid `
            -InstallLocation $networkLocation -BaseURLs @("https://publisher.invalid/fortnite")
        $localBytes = New-ClientTestItemBytes -AppName "Fortnite" -Guid $guid `
            -InstallLocation $networkLocation -BaseURLs @("https://client.invalid/fortnite")
        [IO.File]::WriteAllBytes(
            (Join-Path $script:EgsManifestDirectory "$guid.item"),
            $localBytes
        )
        Set-ClientTestLauncherInstalled -Path $script:EgsLauncherInstalledPath `
            -InstallationList @([ordered]@{
                AppName = "Fortnite"
                InstallLocation = $networkLocation
                AppVersion = "build-1"
                ArtifactId = "Fortnite"
            })
        $launcherHash = Get-EgsSha256Hex (
            [IO.File]::ReadAllBytes($script:EgsLauncherInstalledPath)
        )
        $existing = @(Read-ExistingEgsManifests -ManifestDirectory $script:EgsManifestDirectory)
        $plan = New-ClientEgsSyncPlan -Desired @($desired) -Existing $existing `
            -ManagedState ([pscustomobject]@{ schema_version = 1; manifests = @() })
        $launcherPlan = New-ClientEgsLauncherInstalledPlan `
            -Path $script:EgsLauncherInstalledPath -Desired @($desired)
        Mock Assert-EgsLauncherStopped { }

        Invoke-ClientEgsTransaction -Plan $plan `
            -ManifestDirectory $script:EgsManifestDirectory -StatePath $script:EgsStatePath `
            -TransactionPath $script:EgsTransactionPath `
            -ArchiveDirectory $script:EgsArchiveDirectory `
            -LauncherInstalledPlan $launcherPlan

        @($plan.AdoptedAppNames) | Should -Be @("Fortnite")
        @($plan.DisplacedFileNames) | Should -Be @("$guid.item")
        $launcherPlan.RequiresWrite | Should -BeFalse
        Get-EgsSha256Hex ([IO.File]::ReadAllBytes(
            (Join-Path $script:EgsManifestDirectory "$guid.item")
        )) | Should -Be $desired.Sha256
        Get-EgsSha256Hex ([IO.File]::ReadAllBytes($script:EgsLauncherInstalledPath)) |
            Should -Be $launcherHash
        $localSha = Get-EgsSha256Hex $localBytes
        Get-EgsSha256Hex ([IO.File]::ReadAllBytes(
            (Join-Path (Join-Path $script:EgsArchiveDirectory "items") "$localSha.item")
        )) | Should -Be $localSha
        @((Read-ClientEgsManagedState -Path $script:EgsStatePath).manifests).Count |
            Should -Be 1
    }

    It "takes over a local registration without deleting local game files" {
        $localGuid = "dddddddddddddddddddddddddddddddd"
        $networkGuid = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
        $localLocation = Join-Path $TestDrive "local-fortnite"
        $networkLocation = Join-Path $script:EgsClientRoot "Fortnite"
        New-Item -ItemType Directory -Path $localLocation -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $localLocation "keep.bin") -Value "keep"
        $localBytes = New-ClientTestItemBytes -AppName "Fortnite" -Guid $localGuid `
            -InstallLocation $localLocation -Version "local-build"
        [IO.File]::WriteAllBytes(
            (Join-Path $script:EgsManifestDirectory "$localGuid.item"),
            $localBytes
        )
        $desired = New-ClientTestDesired -AppName "Fortnite" -Guid $networkGuid `
            -InstallLocation $networkLocation -Version "network-build" `
            -WithLauncherRegistration
        Set-ClientTestLauncherInstalled -Path $script:EgsLauncherInstalledPath `
            -InstallationList @(
                [ordered]@{
                    AppName = "Fortnite"
                    InstallLocation = $localLocation
                    AppVersion = "local-build"
                    ArtifactId = "Fortnite"
                },
                [ordered]@{
                    AppName = "Fortnite"
                    InstallLocation = $networkLocation
                    AppVersion = "network-build"
                    ArtifactId = "Fortnite"
                },
                [ordered]@{
                    AppName = "Fortnite"
                    InstallLocation = $networkLocation
                    AppVersion = "network-build"
                    ArtifactId = "duplicate"
                },
                [ordered]@{
                    AppName = "LocalGame"
                    InstallLocation = (Join-Path $TestDrive "local-game")
                    AppVersion = "other-build"
                    UnknownEntryField = "preserve-entry"
                }
            )
        $launcherSourceHash = Get-EgsSha256Hex (
            [IO.File]::ReadAllBytes($script:EgsLauncherInstalledPath)
        )
        $existing = @(Read-ExistingEgsManifests -ManifestDirectory $script:EgsManifestDirectory)
        $plan = New-ClientEgsSyncPlan -Desired @($desired) -Existing $existing `
            -ManagedState ([pscustomobject]@{ schema_version = 1; manifests = @() })
        $launcherPlan = New-ClientEgsLauncherInstalledPlan `
            -Path $script:EgsLauncherInstalledPath -Desired @($desired)
        Mock Assert-EgsLauncherStopped { }

        Invoke-ClientEgsTransaction -Plan $plan `
            -ManifestDirectory $script:EgsManifestDirectory -StatePath $script:EgsStatePath `
            -TransactionPath $script:EgsTransactionPath `
            -ArchiveDirectory $script:EgsArchiveDirectory `
            -LauncherInstalledPlan $launcherPlan

        $launcherPlan.RemovedEntryCount | Should -Be 3
        Test-Path -LiteralPath (Join-Path $localLocation "keep.bin") | Should -BeTrue
        Test-Path -LiteralPath (
            Join-Path $script:EgsManifestDirectory "$localGuid.item"
        ) | Should -BeFalse
        Get-EgsSha256Hex ([IO.File]::ReadAllBytes(
            (Join-Path $script:EgsManifestDirectory "$networkGuid.item")
        )) | Should -Be $desired.Sha256
        $localSha = Get-EgsSha256Hex $localBytes
        Test-Path -LiteralPath (
            Join-Path (Join-Path $script:EgsArchiveDirectory "items") "$localSha.item"
        ) | Should -BeTrue
        Test-Path -LiteralPath (
            Join-Path (Join-Path $script:EgsArchiveDirectory "launcher-installed") `
                "$launcherSourceHash.dat"
        ) | Should -BeTrue
        $launcher = Get-Content -LiteralPath $script:EgsLauncherInstalledPath -Raw |
            ConvertFrom-Json
        @($launcher.InstallationList | Where-Object AppName -eq "Fortnite").Count |
            Should -Be 1
        $fortniteEntry = $launcher.InstallationList | Where-Object AppName -eq "Fortnite"
        @($fortniteEntry.PSObject.Properties.Name | Sort-Object) | Should -Be @(
            "AppName", "AppVersion", "ArtifactId", "InstallLocation", "ItemId", "NamespaceId"
        )
        @($launcher.InstallationList | Where-Object AppName -eq "LocalGame").Count |
            Should -Be 1
        ($launcher.InstallationList | Where-Object AppName -eq "LocalGame").UnknownEntryField |
            Should -Be "preserve-entry"
        $launcher.UnknownTopLevel | Should -Be "preserve-me"
    }

    It "fails closed when the target item filename belongs to another AppName" {
        $guid = "ffffffffffffffffffffffffffffffff"
        $otherBytes = New-ClientTestItemBytes -AppName "GTA5" -Guid $guid `
            -InstallLocation (Join-Path $TestDrive "gta")
        [IO.File]::WriteAllBytes(
            (Join-Path $script:EgsManifestDirectory "$guid.item"),
            $otherBytes
        )
        $desired = New-ClientTestDesired -AppName "Fortnite" -Guid $guid `
            -InstallLocation (Join-Path $script:EgsClientRoot "Fortnite")
        $existing = @(Read-ExistingEgsManifests -ManifestDirectory $script:EgsManifestDirectory)

        {
            New-ClientEgsSyncPlan -Desired @($desired) -Existing $existing `
                -ManagedState ([pscustomobject]@{ schema_version = 1; manifests = @() })
        } | Should -Throw "*belongs to another local application*"
    }

    It "accepts a missing LauncherInstalled.dat and rejects invalid JSON" {
        $desired = New-ClientTestDesired -AppName "Fortnite" `
            -Guid "abababababababababababababababab" `
            -InstallLocation (Join-Path $script:EgsClientRoot "Fortnite")
        $missing = New-ClientEgsLauncherInstalledPlan `
            -Path $script:EgsLauncherInstalledPath -Desired @($desired)
        $missing.RequiresWrite | Should -BeFalse

        Set-Content -LiteralPath $script:EgsLauncherInstalledPath -Value "not-json"
        {
            New-ClientEgsLauncherInstalledPlan `
                -Path $script:EgsLauncherInstalledPath -Desired @($desired)
        } | Should -Throw "*not valid JSON*"
    }

    It "fails before mutations when LauncherInstalled.dat changes after planning" {
        $desired = New-ClientTestDesired -AppName "Fortnite" `
            -Guid "10101010101010101010101010101010" `
            -InstallLocation (Join-Path $script:EgsClientRoot "Fortnite")
        Set-ClientTestLauncherInstalled -Path $script:EgsLauncherInstalledPath `
            -InstallationList @([ordered]@{
                AppName = "Fortnite"
                InstallLocation = (Join-Path $TestDrive "local-fortnite")
                AppVersion = "local-build"
            })
        $launcherPlan = New-ClientEgsLauncherInstalledPlan `
            -Path $script:EgsLauncherInstalledPath -Desired @($desired)
        Set-Content -LiteralPath $script:EgsLauncherInstalledPath -Value "changed"

        {
            Start-ClientEgsTransaction -ManifestDirectory $script:EgsManifestDirectory `
                -StatePath $script:EgsStatePath `
                -TransactionPath $script:EgsTransactionPath `
                -AffectedFileNames @($desired.TargetFileName) `
                -LauncherInstalledPlan $launcherPlan
        } | Should -Throw "*changed before transaction*"
        Test-Path -LiteralPath $script:EgsTransactionPath | Should -BeFalse
        Test-Path -LiteralPath (
            Join-Path $script:EgsManifestDirectory $desired.TargetFileName
        ) | Should -BeFalse
    }

    It "rolls back item, state, and LauncherInstalled.dat after the launcher mutation" {
        $localGuid = "12121212121212121212121212121212"
        $networkGuid = "34343434343434343434343434343434"
        $localLocation = Join-Path $TestDrive "local-fortnite"
        $networkLocation = Join-Path $script:EgsClientRoot "Fortnite"
        New-Item -ItemType Directory -Path $localLocation -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $localLocation "keep.bin") -Value "keep"
        $localBytes = New-ClientTestItemBytes -AppName "Fortnite" -Guid $localGuid `
            -InstallLocation $localLocation -Version "local-build"
        $localItemPath = Join-Path $script:EgsManifestDirectory "$localGuid.item"
        [IO.File]::WriteAllBytes($localItemPath, $localBytes)
        $desired = New-ClientTestDesired -AppName "Fortnite" -Guid $networkGuid `
            -InstallLocation $networkLocation -Version "network-build"
        Set-ClientTestLauncherInstalled -Path $script:EgsLauncherInstalledPath `
            -InstallationList @([ordered]@{
                AppName = "Fortnite"
                InstallLocation = $localLocation
                AppVersion = "local-build"
            })
        $launcherHash = Get-EgsSha256Hex (
            [IO.File]::ReadAllBytes($script:EgsLauncherInstalledPath)
        )
        $existing = @(Read-ExistingEgsManifests -ManifestDirectory $script:EgsManifestDirectory)
        $plan = New-ClientEgsSyncPlan -Desired @($desired) -Existing $existing `
            -ManagedState ([pscustomobject]@{ schema_version = 1; manifests = @() })
        $launcherPlan = New-ClientEgsLauncherInstalledPlan `
            -Path $script:EgsLauncherInstalledPath -Desired @($desired)
        Mock Assert-EgsLauncherStopped { }
        Mock Stop-EgsLauncherProcesses { }
        $script:InjectStateWriteFailure = $true
        Mock Write-EgsBytesAtomic {
            if ($script:InjectStateWriteFailure -and $Path -eq $script:EgsStatePath) {
                $script:InjectStateWriteFailure = $false
                throw "injected after LauncherInstalled.dat mutation"
            }
            $parent = Split-Path $Path -Parent
            if (-not (Test-Path -LiteralPath $parent)) {
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
            }
            [IO.File]::WriteAllBytes($Path, $Bytes)
        }

        {
            Invoke-ClientEgsTransaction -Plan $plan `
                -ManifestDirectory $script:EgsManifestDirectory `
                -StatePath $script:EgsStatePath `
                -TransactionPath $script:EgsTransactionPath `
                -ArchiveDirectory $script:EgsArchiveDirectory `
                -LauncherInstalledPlan $launcherPlan
        } | Should -Throw "*injected after LauncherInstalled.dat mutation*"

        Get-EgsSha256Hex ([IO.File]::ReadAllBytes($localItemPath)) |
            Should -Be (Get-EgsSha256Hex $localBytes)
        Test-Path -LiteralPath (
            Join-Path $script:EgsManifestDirectory "$networkGuid.item"
        ) | Should -BeFalse
        Test-Path -LiteralPath $script:EgsStatePath | Should -BeFalse
        Get-EgsSha256Hex ([IO.File]::ReadAllBytes($script:EgsLauncherInstalledPath)) |
            Should -Be $launcherHash
        Test-Path -LiteralPath (Join-Path $localLocation "keep.bin") | Should -BeTrue
        Test-Path -LiteralPath $script:EgsTransactionPath | Should -BeFalse

        Invoke-ClientEgsTransaction -Plan $plan `
            -ManifestDirectory $script:EgsManifestDirectory -StatePath $script:EgsStatePath `
            -TransactionPath $script:EgsTransactionPath `
            -ArchiveDirectory $script:EgsArchiveDirectory `
            -LauncherInstalledPlan $launcherPlan
        Test-Path -LiteralPath (
            Join-Path $script:EgsManifestDirectory "$networkGuid.item"
        ) | Should -BeTrue
        @((Read-ClientEgsManagedState -Path $script:EgsStatePath).manifests).Count |
            Should -Be 1
    }

    It "restores a version 1 transaction journal left by v0.4.6" {
        $guid = "56565656565656565656565656565656"
        $location = Join-Path $script:EgsClientRoot "Fortnite"
        $originalBytes = New-ClientTestItemBytes -AppName "Fortnite" -Guid $guid `
            -InstallLocation $location -Version "original"
        $changedBytes = New-ClientTestItemBytes -AppName "Fortnite" -Guid $guid `
            -InstallLocation $location -Version "changed"
        $itemPath = Join-Path $script:EgsManifestDirectory "$guid.item"
        [IO.File]::WriteAllBytes($itemPath, $changedBytes)
        $originalState = [Text.Encoding]::UTF8.GetBytes(
            (@{ schema_version = 1; manifests = @() } | ConvertTo-Json)
        )
        [IO.File]::WriteAllBytes($script:EgsStatePath, [Text.Encoding]::UTF8.GetBytes("changed"))
        $backupDirectory = Join-Path $script:EgsTransactionPath "backup"
        New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $backupDirectory "0.bak"), $originalBytes)
        [IO.File]::WriteAllBytes((Join-Path $backupDirectory "state.bak"), $originalState)
        [ordered]@{
            schema_version = 1
            manifest_directory = $script:EgsManifestDirectory
            state_path = $script:EgsStatePath
            files = @([ordered]@{
                file_name = "$guid.item"
                existed = $true
                sha256 = Get-EgsSha256Hex $originalBytes
                backup_name = "0.bak"
            })
            state_existed = $true
            state_sha256 = Get-EgsSha256Hex $originalState
        } | ConvertTo-Json -Depth 6 | Set-Content `
            -LiteralPath (Join-Path $script:EgsTransactionPath "journal.json")
        Mock Assert-EgsLauncherStopped { }

        Restore-ClientEgsTransaction -TransactionPath $script:EgsTransactionPath

        Get-EgsSha256Hex ([IO.File]::ReadAllBytes($itemPath)) |
            Should -Be (Get-EgsSha256Hex $originalBytes)
        Get-EgsSha256Hex ([IO.File]::ReadAllBytes($script:EgsStatePath)) |
            Should -Be (Get-EgsSha256Hex $originalState)
        Test-Path -LiteralPath $script:EgsTransactionPath | Should -BeFalse
    }

    It "gracefully requests close and force-stops remaining launcher processes" {
        $script:EgsStopped = $false
        $launcher = [pscustomobject]@{ ProcessName = "EpicGamesLauncher"; Id = 10 }
        $launcher | Add-Member -MemberType ScriptMethod -Name CloseMainWindow -Value { return $true }
        Mock Get-Process {
            if ($script:EgsStopped) { return @() }
            return @($launcher)
        }
        Mock Stop-Process { $script:EgsStopped = $true }
        Mock Start-Sleep { }

        Stop-EgsLauncherProcesses -GraceSeconds 0

        Should -Invoke Stop-Process -Times 1 -Exactly -ParameterFilter { $Id -eq 10 -and $Force }
    }
}

Describe "Epic Games aggressive ProgramData payload" {
    BeforeEach {
        $script:AggressiveRoot = Join-Path $TestDrive "aggressive"
        Remove-Item -LiteralPath $script:AggressiveRoot -Recurse -Force `
            -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Path $script:AggressiveRoot -Force | Out-Null
        $script:AggressiveIndexPath = Join-Path $script:AggressiveRoot "index.json"
        $script:AggressiveArchivePath = Join-Path $script:AggressiveRoot "payload.zip"
        $script:AggressiveTimestamp = "2026-08-23T12:00:00.0000000Z"
    }

    BeforeAll {
        function New-AggressiveTestPayload {
            param([switch]$Collision, [switch]$Traversal)
            Initialize-EgsZipSupport
            $path1 = if ($Traversal) { "EpicGamesLauncher/Data/../escape.bin" } else {
                "EpicGamesLauncher/Data/Manifests/one.item"
            }
            $fileDefinitions = @(
                [pscustomobject]@{ Path = $path1; Bytes = [Text.Encoding]::UTF8.GetBytes("one") },
                [pscustomobject]@{ Path = "UnrealEngineLauncher/LauncherInstalled.dat"; Bytes = [Text.Encoding]::UTF8.GetBytes('{"InstallationList":[]}') }
            )
            if ($Collision) {
                $fileDefinitions += [pscustomobject]@{
                    Path = "EpicGamesLauncher/Data/Manifests/ONE.item"
                    Bytes = [Text.Encoding]::UTF8.GetBytes("collision")
                }
            }
            $files = @($fileDefinitions | ForEach-Object {
                [ordered]@{
                    relative_path = $_.Path
                    length = [Int64]$_.Bytes.Length
                    sha256 = Get-EgsSha256Hex $_.Bytes
                    attributes = [int][IO.FileAttributes]::Normal
                    creation_time_utc = $script:AggressiveTimestamp
                    last_write_time_utc = $script:AggressiveTimestamp
                }
            })
            $totalBytes = [Int64]0
            foreach ($definition in $fileDefinitions) {
                $totalBytes += [Int64]$definition.Bytes.Length
            }
            $index = [ordered]@{
                schema_version = 1
                file_count = $files.Count
                total_bytes = $totalBytes
                directories = @(
                    [ordered]@{ relative_path = "EpicGamesLauncher"; attributes = 16; creation_time_utc = $script:AggressiveTimestamp; last_write_time_utc = $script:AggressiveTimestamp },
                    [ordered]@{ relative_path = "EpicGamesLauncher/Data"; attributes = 16; creation_time_utc = $script:AggressiveTimestamp; last_write_time_utc = $script:AggressiveTimestamp },
                    [ordered]@{ relative_path = "EpicGamesLauncher/Data/Manifests"; attributes = 16; creation_time_utc = $script:AggressiveTimestamp; last_write_time_utc = $script:AggressiveTimestamp },
                    [ordered]@{ relative_path = "UnrealEngineLauncher"; attributes = 16; creation_time_utc = $script:AggressiveTimestamp; last_write_time_utc = $script:AggressiveTimestamp }
                )
                files = $files
            }
            $indexBytes = [Text.Encoding]::UTF8.GetBytes(($index | ConvertTo-Json -Depth 8))
            [IO.File]::WriteAllBytes($script:AggressiveIndexPath, $indexBytes)
            $zip = [IO.Compression.ZipFile]::Open(
                $script:AggressiveArchivePath, [IO.Compression.ZipArchiveMode]::Create
            )
            try {
                foreach ($directory in $index.directories) {
                    $zip.CreateEntry("$($directory.relative_path)/") | Out-Null
                }
                foreach ($definition in $fileDefinitions) {
                    $entry = $zip.CreateEntry($definition.Path)
                    $stream = $entry.Open()
                    try { $stream.Write($definition.Bytes, 0, $definition.Bytes.Length) } finally {
                        $stream.Dispose()
                    }
                }
            } finally { $zip.Dispose() }
            return [pscustomobject]@{
                archive_length = [Int64](Get-Item $script:AggressiveArchivePath).Length
                archive_sha256 = Get-EgsFileSha256Hex $script:AggressiveArchivePath
                index_length = [Int64]$indexBytes.Length
                index_sha256 = Get-EgsSha256Hex $indexBytes
                tree_sha256 = Get-EgsSha256Hex $indexBytes
                file_count = $files.Count
                total_bytes = [Int64]$index.total_bytes
            }
        }
    }

    It "verifies and extracts an exact indexed ProgramData payload" {
        $metadata = New-AggressiveTestPayload
        $index = Read-ClientEgsAggressiveIndex -Path $script:AggressiveIndexPath `
            -ArchiveMetadata $metadata
        $stage = Join-Path $script:AggressiveRoot "stage"

        Expand-ClientEgsAggressiveArchive -ArchivePath $script:AggressiveArchivePath `
            -ArchiveMetadata $metadata -IndexData $index -StagePath $stage

        Get-Content -LiteralPath (Join-Path $stage `
            "EpicGamesLauncher/Data/Manifests/one.item") -Raw | Should -Be "one"
        Get-Content -LiteralPath (Join-Path $stage `
            "UnrealEngineLauncher/LauncherInstalled.dat") -Raw |
            Should -Be '{"InstallationList":[]}'
    }

    It "rejects traversal and case-insensitive path collisions before extraction" {
        $metadata = New-AggressiveTestPayload -Traversal
        {
            Read-ClientEgsAggressiveIndex -Path $script:AggressiveIndexPath `
                -ArchiveMetadata $metadata
        } | Should -Throw "*unsafe relative path*"
        Remove-Item -LiteralPath $script:AggressiveArchivePath -Force
        $metadata = New-AggressiveTestPayload -Collision
        {
            Read-ClientEgsAggressiveIndex -Path $script:AggressiveIndexPath `
                -ArchiveMetadata $metadata
        } | Should -Throw "*duplicate relative path*"
    }

    It "restores a version 3 directory-swap journal exactly" {
        $programData = Join-Path $script:AggressiveRoot "Data"
        $launcher = Join-Path $script:AggressiveRoot "LauncherInstalled.dat"
        $state = Join-Path $script:AggressiveRoot "managed.json"
        $aggressiveState = Join-Path $script:AggressiveRoot "aggressive.json"
        $stage = Join-Path $script:AggressiveRoot "stage"
        $transaction = Join-Path $script:AggressiveRoot "transaction"
        New-Item -ItemType Directory -Path $programData -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $programData "old.bin") -Value "old"
        Set-Content -LiteralPath $launcher -Value "old-launcher"
        Set-Content -LiteralPath $state -Value "old-state"
        Set-Content -LiteralPath $aggressiveState -Value "old-aggressive"
        New-Item -ItemType Directory -Path $stage -Force | Out-Null
        Mock Assert-EgsLauncherStopped { }
        $journal = Start-ClientEgsAggressiveTransaction -TransactionPath $transaction `
            -ProgramDataPath $programData -LauncherInstalledPath $launcher `
            -StatePath $state -AggressiveStatePath $aggressiveState -StagePath $stage
        Move-Item -LiteralPath $programData -Destination (Join-Path $transaction "backup/Data")
        New-Item -ItemType Directory -Path $programData -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $programData "new.bin") -Value "new"
        Set-Content -LiteralPath $launcher -Value "new-launcher"
        Set-Content -LiteralPath $state -Value "new-state"
        Set-Content -LiteralPath $aggressiveState -Value "new-aggressive"

        Restore-ClientEgsTransaction -TransactionPath $transaction

        Get-Content -LiteralPath (Join-Path $programData "old.bin") -Raw |
            Should -Match "old"
        Test-Path -LiteralPath (Join-Path $programData "new.bin") | Should -BeFalse
        Get-Content -LiteralPath $launcher -Raw | Should -Match "old-launcher"
        Get-Content -LiteralPath $state -Raw | Should -Match "old-state"
        Get-Content -LiteralPath $aggressiveState -Raw | Should -Match "old-aggressive"
        Test-Path -LiteralPath $transaction | Should -BeFalse
    }
}
