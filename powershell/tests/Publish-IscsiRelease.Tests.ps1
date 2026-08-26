BeforeAll {
    $script:PublisherScriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) "Publish-IscsiRelease.ps1"
    . $script:PublisherScriptPath -NoMain
    foreach ($name in @(
        "Get-IscsiSession", "Get-IscsiTargetPortal", "New-IscsiTargetPortal",
        "Get-IscsiTarget", "Disconnect-IscsiTarget"
    )) {
        if ($null -eq (Get-Command $name -ErrorAction SilentlyContinue)) {
            Set-Item -Path "function:$name" -Value { }
        }
    }
    if ($null -eq (Get-Command Update-IscsiTargetPortal -ErrorAction SilentlyContinue)) {
        Set-Item -Path "function:Update-IscsiTargetPortal" -Value {
            param($TargetPortalAddress, $TargetPortalPortNumber)
        }
    }
    if ($null -eq (Get-Command Get-Disk -ErrorAction SilentlyContinue)) {
        Set-Item -Path "function:Get-Disk" -Value { param($Number) }
    }
    if ($null -eq (Get-Command Set-Disk -ErrorAction SilentlyContinue)) {
        Set-Item -Path "function:Set-Disk" -Value { param($Number, $IsOffline) }
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

Describe "Publisher helper safety" {
    It "resolves the default EGS config beside the script and preserves an override" {
        Resolve-PublisherEgsSyncConfigPath -Path "" | Should -Be (
            Join-Path (Split-Path $script:PublisherScriptPath -Parent) "egs-sync.json"
        )
        Resolve-PublisherEgsSyncConfigPath -Path "D:\custom\egs-sync.json" |
            Should -Be "D:\custom\egs-sync.json"
    }

    It "starts through a child PowerShell process without an explicit EGS config path" {
        $powerShell = (Get-Process -Id $PID).Path
        $output = @(& $powerShell -NoLogo -NoProfile -NonInteractive `
            -ExecutionPolicy Bypass -File $script:PublisherScriptPath -NoMain 2>&1)
        $exitCode = $LASTEXITCODE

        $exitCode | Should -Be 0 -Because ($output -join [Environment]::NewLine)
    }

    It "normalizes only case, whitespace, and the optional 0x prefix" {
        Normalize-PublisherDiskId " 0x65 89CF " | Should -Be "6589cf"
        Normalize-PublisherDiskId "EUI.001" | Should -Be "eui.001"
    }

    It "contains no network API or destructive provisioning commands" {
        $source = Get-Content -LiteralPath $script:PublisherScriptPath -Raw
        $source | Should -Not -Match "(?i)Invoke-RestMethod|Authorization|CertificateThumbprint|admin\.token"
        $source | Should -Not -Match "(?im)^\s*(Initialize-Disk|Format-Volume|Clear-Disk|New-Partition)\b"
    }

    It "rejects the complete disk set before mutations when an NAA is absent" {
        $expected = @(
            [pscustomobject]@{ disk_unique_id = "aaa" },
            [pscustomobject]@{ disk_unique_id = "bbb" }
        )
        $disks = @(
            [pscustomobject]@{ UniqueId = "0xaaa"; Number = 10 },
            [pscustomobject]@{ UniqueId = "0xwrong"; Number = 11 }
        )
        { Assert-PublisherDisks -ExpectedVolumes $expected -Disks $disks } | Should -Throw
    }

    It "attempts to offline every matched disk after a partial Set-Disk failure" {
        $script:SetCalls = 0
        $disks = @(
            [pscustomobject]@{ UniqueId = "aaa"; Number = 10; IsOffline = $false },
            [pscustomobject]@{ UniqueId = "bbb"; Number = 11; IsOffline = $false }
        )
        Mock Set-Disk {
            $script:SetCalls++
            if ($Number -eq 10) { throw "injected" }
        }
        Mock Get-Disk {
            if ($Number -eq 10) { return [pscustomobject]@{ Number = 10; IsOffline = $false } }
            return [pscustomobject]@{ Number = 11; IsOffline = $true }
        }

        { Set-PublisherDisksOffline -Disks $disks } | Should -Throw
        Should -Invoke Set-Disk -Times 2 -Exactly
    }
}

Describe "Publisher target discovery" {
    BeforeEach {
        $script:DiscoveryTarget = "iqn.2026-08.lab.games:master"
        $script:DiscoveryPortal = [pscustomobject]@{ address = "10.20.40.10"; port = 3260 }
        $script:DiscoveryQueries = 0
        $script:DiscoveryRefreshes = 0
        Mock Update-IscsiTargetPortal { $script:DiscoveryRefreshes++ }
        Mock Get-IscsiTarget {
            $script:DiscoveryQueries++
            return [pscustomobject]@{ NodeAddress = $script:DiscoveryTarget }
        }
        Mock Start-Sleep { }
    }

    It "returns immediately when the exact target is available" {
        $target = Wait-PublisherTargetDiscovery -TargetIqn $script:DiscoveryTarget `
            -Portal $script:DiscoveryPortal

        $target.NodeAddress | Should -Be $script:DiscoveryTarget
        Should -Invoke Update-IscsiTargetPortal -Times 1 -Exactly -ParameterFilter {
            $TargetPortalAddress -eq "10.20.40.10" -and $TargetPortalPortNumber -eq 3260
        }
        Should -Invoke Get-IscsiTarget -Times 1 -Exactly
        Should -Invoke Start-Sleep -Times 0 -Exactly
    }

    It "ignores other targets and tolerates a transient refresh failure" {
        Mock Update-IscsiTargetPortal {
            $script:DiscoveryRefreshes++
            if ($script:DiscoveryRefreshes -eq 1) { throw "transient refresh failure" }
        }
        Mock Get-IscsiTarget {
            $script:DiscoveryQueries++
            if ($script:DiscoveryQueries -lt 3) {
                return [pscustomobject]@{ NodeAddress = "iqn.2026-08.lab.games:other" }
            }
            return [pscustomobject]@{ NodeAddress = $script:DiscoveryTarget }
        }

        $target = Wait-PublisherTargetDiscovery -TargetIqn $script:DiscoveryTarget `
            -Portal $script:DiscoveryPortal

        $target.NodeAddress | Should -Be $script:DiscoveryTarget
        Should -Invoke Update-IscsiTargetPortal -Times 3 -Exactly
        Should -Invoke Get-IscsiTarget -Times 3 -Exactly
        Should -Invoke Start-Sleep -Times 2 -Exactly -ParameterFilter { $Seconds -eq 1 }
    }

    It "times out after exactly sixty checks" {
        Mock Get-IscsiTarget {
            return [pscustomobject]@{ NodeAddress = "iqn.2026-08.lab.games:other" }
        }

        {
            Wait-PublisherTargetDiscovery -TargetIqn $script:DiscoveryTarget `
                -Portal $script:DiscoveryPortal
        } | Should -Throw "*not discovered after 60 attempts*"

        Should -Invoke Update-IscsiTargetPortal -Times 60 -Exactly
        Should -Invoke Get-IscsiTarget -Times 60 -Exactly
        Should -Invoke Start-Sleep -Times 59 -Exactly -ParameterFilter { $Seconds -eq 1 }
    }
}

Describe "Publisher Majestic Launcher settings bundles" {
    BeforeEach {
        foreach ($leaf in @("publisher-profile", "nvme", "archive", "bonus", "dup")) {
            $candidate = Join-Path $TestDrive $leaf
            $existing = Get-Item -LiteralPath $candidate -Force `
                -ErrorAction SilentlyContinue
            if ($null -ne $existing) {
                if ((([int]$existing.Attributes -band
                    [int][IO.FileAttributes]::ReparsePoint) -ne 0)) {
                    [IO.Directory]::Delete($existing.FullName, $false)
                } else {
                    Remove-Item -LiteralPath $existing.FullName -Recurse -Force
                }
            }
        }
        $script:MajesticProfile = Join-Path $TestDrive "publisher-profile"
        $prefsDirectory = Join-Path $script:MajesticProfile `
            "AppData/Roaming/majestic-launcher"
        New-Item -ItemType Directory -Path $prefsDirectory -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:MajesticProfile "NTUSER.DAT") `
            -Value "hive"
        $script:MajesticPrefsBytes = [Text.Encoding]::UTF8.GetBytes(
            '{"windowState":{"v2":{"main":{"maximized":true}}},"selectedProject":"ro","gameInstall":{"persisted":{"source":"custom","path":"E:\\SteamLibrary\\steamapps\\common\\Grand Theft Auto V"}},"gameDisk":"E:","settings":{"lastVisitedServerIdRo":"ro3"}}'
        )
        [IO.File]::WriteAllBytes(
            (Join-Path $prefsDirectory "prefs.latest.json"),
            $script:MajesticPrefsBytes
        )
        $multiplayerDirectory = Join-Path $prefsDirectory "Multiplayer"
        New-Item -ItemType Directory -Path $multiplayerDirectory -Force | Out-Null
        $script:MajesticConfigBytes = [Text.Encoding]::UTF8.GetBytes(
            '{"gtapath":"E:\\SteamLibrary\\GTA V","name":"xrzvs"}'
        )
        $script:MajesticHashMapBytes = [Text.Encoding]::UTF8.GetBytes(
            '{"GTA5.exe":"verification-hash","update.rpf":"other-hash"}'
        )
        $script:MajesticGeneralHashMapBytes = [Text.Encoding]::UTF8.GetBytes(
            '{"GTA5.exe":"general-hash","PlayGTAV.exe":"other-general-hash"}'
        )
        [IO.File]::WriteAllBytes(
            (Join-Path $multiplayerDirectory "majestic.json"),
            $script:MajesticConfigBytes
        )
        [IO.File]::WriteAllBytes(
            (Join-Path $prefsDirectory "hashMap_v3_RO.json"),
            $script:MajesticHashMapBytes
        )
        [IO.File]::WriteAllBytes(
            (Join-Path $prefsDirectory "hashMap_v3.json"),
            $script:MajesticGeneralHashMapBytes
        )
        $script:MajesticBackupDirectory = Join-Path $multiplayerDirectory "backup"
        New-Item -ItemType Directory -Path $script:MajesticBackupDirectory -Force |
            Out-Null
        $script:MajesticBackupFiles = [ordered]@{
            "GTA5.exe" = [byte[]](1, 2, 3, 4, 5)
            "680a1b3170ad45a89f750f4ad48c0b21.bin" = [byte[]](6, 7, 8)
            "extra.bin" = [byte[]](9, 10, 11, 12)
        }
        foreach ($entry in $script:MajesticBackupFiles.GetEnumerator()) {
            [IO.File]::WriteAllBytes(
                (Join-Path $script:MajesticBackupDirectory $entry.Key),
                $entry.Value
            )
            [IO.File]::SetLastWriteTimeUtc(
                (Join-Path $script:MajesticBackupDirectory $entry.Key),
                [DateTime]::SpecifyKind([DateTime]"2026-08-20T12:34:56", "Utc")
            )
        }
        $backupMap = [ordered]@{
            version = 1
            backupDir = $script:MajesticBackupDirectory
            files = [ordered]@{
                "GTA5.exe" = [ordered]@{
                    size = 5; mtimeNs = "1787644592547527100"
                    finalHash = "60694b13a70d4081"
                    publisherOnlyPath = $script:MajesticBackupDirectory
                }
                "680a1b3170ad45a89f750f4ad48c0b21.bin" = [ordered]@{
                    size = 3; mtimeNs = "1787673066827856900"
                    finalHash = "a032e37c13c599b9"
                }
            }
        } | ConvertTo-Json -Depth 6 -Compress
        $script:MajesticBackupMapBytes = [Text.Encoding]::UTF8.GetBytes($backupMap)
        [IO.File]::WriteAllBytes(
            (Join-Path $prefsDirectory "backupMap.json"),
            $script:MajesticBackupMapBytes
        )
        $script:MajesticConfig = [pscustomobject]@{
            Present = $true
            Enabled = $true
            UserSid = "S-1-5-21-100-200-300-1001"
            ProfilePath = $script:MajesticProfile
        }
        $script:MajesticManifest = [pscustomobject]@{
            config_revision = "majestic-revision"
        }
        $script:MajesticMappings = @(
            [pscustomobject]@{ Name = "nvme"; DriveLetter = "E"; RootPath = (Join-Path $TestDrive "nvme") }
            [pscustomobject]@{ Name = "archive"; DriveLetter = "H"; RootPath = (Join-Path $TestDrive "archive") }
            [pscustomobject]@{ Name = "bonus"; DriveLetter = "T"; RootPath = (Join-Path $TestDrive "bonus") }
        )
        foreach ($mapping in $script:MajesticMappings) {
            New-Item -ItemType Directory -Path $mapping.RootPath -Force | Out-Null
        }
        Mock Get-MajesticRegistryValues {
            return [pscustomobject]@{
                lastVisitedServerID = "ro3"
                game_disk = "H:"
            }
        }
        Mock Get-Process { return @() } -ParameterFilter { $Name -eq "Majestic Launcher" }
    }

    It "reads a strict enabled profile config and treats a missing config as legacy disabled" {
        $missing = Get-MajesticSyncConfig -Path (Join-Path $TestDrive "missing.json")
        $missing.Present | Should -BeFalse
        $missing.Enabled | Should -BeFalse

        $path = Join-Path $TestDrive "majestic-sync.json"
        @{
            schema_version = 1
            mode = "enabled"
            user_sid = $script:MajesticConfig.UserSid
            profile_path = $script:MajesticProfile
        } | ConvertTo-Json | Set-Content -LiteralPath $path
        $enabled = Get-MajesticSyncConfig -Path $path
        $enabled.Present | Should -BeTrue
        $enabled.Enabled | Should -BeTrue
        $enabled.UserSid | Should -Be $script:MajesticConfig.UserSid
    }

    It "migrates backup only to prefs gameDisk and writes identical exact-byte bundles" {
        $originalTimes = @{}
        foreach ($entry in $script:MajesticBackupFiles.GetEnumerator()) {
            $originalTimes[$entry.Key] = (Get-Item -LiteralPath (
                Join-Path $script:MajesticBackupDirectory $entry.Key
            )).LastWriteTimeUtc.Ticks
        }

        Invoke-PublisherMajesticSync -Config $script:MajesticConfig `
            -Manifest $script:MajesticManifest -VolumeMappings $script:MajesticMappings

        $hashes = @()
        foreach ($mapping in $script:MajesticMappings) {
            $path = Get-PublisherMajesticBundlePath -VolumeMapping $mapping
            $written = [IO.File]::ReadAllBytes($path)
            $hashes += Get-EgsSha256Hex $written
            $bundle = [Text.Encoding]::UTF8.GetString($written) | ConvertFrom-Json
            $bundle.schema_version | Should -Be 2
            (Get-EgsSha256Hex ([Convert]::FromBase64String(
                [string]$bundle.files.prefs_latest_json.base64
            ))) | Should -Be (Get-EgsSha256Hex $script:MajesticPrefsBytes)
            (Get-EgsSha256Hex ([Convert]::FromBase64String(
                [string]$bundle.files.multiplayer_majestic_json.base64
            ))) | Should -Be (Get-EgsSha256Hex $script:MajesticConfigBytes)
            (Get-EgsSha256Hex ([Convert]::FromBase64String(
                [string]$bundle.files.hash_map_v3_ro_json.base64
            ))) | Should -Be (Get-EgsSha256Hex $script:MajesticHashMapBytes)
            (Get-EgsSha256Hex ([Convert]::FromBase64String(
                [string]$bundle.files.hash_map_v3_json.base64
            ))) | Should -Be (Get-EgsSha256Hex $script:MajesticGeneralHashMapBytes)
            $bundle.backup_map.version | Should -Be 1
            $bundle.backup_map.files."GTA5.exe".finalHash |
                Should -Be "60694b13a70d4081"
            $bundle.backup_map.PSObject.Properties.Name |
                Should -Not -Contain "backupDir"
            $bundle.PSObject.Properties.Name | Should -Not -Contain "backup_directory"
            $bundle.registry.lastVisitedServerID | Should -Be "ro3"
            $bundle.registry.game_disk | Should -Be "H:"
            $bundle.PSObject.Properties.Name | Should -Not -Contain "profile_path"
            $bundle.PSObject.Properties.Name | Should -Not -Contain "user_sid"
            [Text.Encoding]::UTF8.GetString($written) |
                Should -Not -Match "publisher-profile|backupDir"
            Test-Path -LiteralPath (
                Get-PublisherMajesticBundlePath -VolumeMapping $mapping `
                    -SchemaVersion 1
            ) | Should -BeFalse
        }
        @($hashes | Select-Object -Unique).Count | Should -Be 1
        $payloadPath = Get-PublisherMajesticBackupPayloadPath `
            -VolumeMapping $script:MajesticMappings[0]
        foreach ($entry in $script:MajesticBackupFiles.GetEnumerator()) {
            $copied = Join-Path $payloadPath $entry.Key
            (Get-EgsFileSha256Hex $copied) | Should -Be (Get-EgsSha256Hex $entry.Value)
            (Get-Item -LiteralPath $copied).LastWriteTimeUtc.Ticks |
                Should -Be $originalTimes[$entry.Key]
        }
        ((Get-Item -LiteralPath $script:MajesticBackupDirectory -Force).Attributes -band
            [IO.FileAttributes]::ReparsePoint) | Should -Not -Be 0
        foreach ($mapping in @($script:MajesticMappings[1], $script:MajesticMappings[2])) {
            Test-Path -LiteralPath (
                Get-PublisherMajesticBackupPayloadPath -VolumeMapping $mapping
            ) | Should -BeFalse
        }
    }

    It "does not copy or hash backup files after the Publisher junction exists" {
        Invoke-PublisherMajesticSync -Config $script:MajesticConfig `
            -Manifest $script:MajesticManifest -VolumeMappings $script:MajesticMappings
        Mock Get-PublisherMajesticBackupIndex {
            throw "backup index must not be rebuilt"
        }
        Mock Get-EgsFileSha256Hex { throw "backup files must not be hashed" }

        Invoke-PublisherMajesticSync -Config $script:MajesticConfig `
            -Manifest $script:MajesticManifest -VolumeMappings $script:MajesticMappings

        Should -Invoke Get-PublisherMajesticBackupIndex -Times 0 -Exactly
        Should -Invoke Get-EgsFileSha256Hex -Times 0 -Exactly
        foreach ($mapping in $script:MajesticMappings) {
            Test-Path -LiteralPath (
                Get-PublisherMajesticBundlePath -VolumeMapping $mapping
            ) | Should -BeTrue
        }
    }

    It "reconciles an interruption after payload commit and source rename" {
        $anchor = Get-PublisherMajesticAnchorVolume `
            -VolumeMappings $script:MajesticMappings -GameDisk "E:"
        Assert-PublisherMajesticHelperDirectory -VolumeMapping $anchor -Create
        $active = Get-PublisherMajesticBackupPayloadPath -VolumeMapping $anchor
        $previous = Get-PublisherMajesticBackupPreviousPath `
            -BackupPath $script:MajesticBackupDirectory
        $index = Get-PublisherMajesticBackupIndex `
            -Path $script:MajesticBackupDirectory
        Copy-PublisherMajesticBackupOnce -BackupIndex $index -Destination $active
        [IO.Directory]::Move($script:MajesticBackupDirectory, $previous)

        Ensure-PublisherMajesticBackupJunction -Config $script:MajesticConfig `
            -AnchorVolume $anchor | Out-Null

        ((Get-Item -LiteralPath $script:MajesticBackupDirectory -Force).Attributes -band
            [IO.FileAttributes]::ReparsePoint) | Should -Not -Be 0
        Test-Path -LiteralPath $previous | Should -BeFalse
        Test-Path -LiteralPath (
            Get-PublisherMajesticBackupPayloadPath -VolumeMapping $anchor -Kind staging
        ) | Should -BeFalse
    }

    It "restores the source and retries after junction creation fails" {
        $anchor = Get-PublisherMajesticAnchorVolume `
            -VolumeMappings $script:MajesticMappings -GameDisk "E:"
        $script:FailMajesticJunctionCreation = $true
        Mock New-PublisherMajesticBackupJunction {
            if ($script:FailMajesticJunctionCreation) {
                throw "injected junction creation failure"
            }
            $itemType = if (
                [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
            ) { "Junction" } else { "SymbolicLink" }
            New-Item -ItemType $itemType -Path $Path -Target $Target |
                Out-Null
        }

        {
            Ensure-PublisherMajesticBackupJunction -Config $script:MajesticConfig `
                -AnchorVolume $anchor
        } | Should -Throw "*injected junction creation failure*"
        ((Get-Item -LiteralPath $script:MajesticBackupDirectory -Force).Attributes -band
            [IO.FileAttributes]::ReparsePoint) | Should -Be 0
        Test-Path -LiteralPath (
            Get-PublisherMajesticBackupPreviousPath `
                -BackupPath $script:MajesticBackupDirectory
        ) | Should -BeFalse

        $script:FailMajesticJunctionCreation = $false
        Ensure-PublisherMajesticBackupJunction -Config $script:MajesticConfig `
            -AnchorVolume $anchor | Out-Null
        ((Get-Item -LiteralPath $script:MajesticBackupDirectory -Force).Attributes -band
            [IO.FileAttributes]::ReparsePoint) | Should -Not -Be 0
    }

    It "blocks when migration staging cleanup cannot be proven" {
        $anchor = Get-PublisherMajesticAnchorVolume `
            -VolumeMappings $script:MajesticMappings -GameDisk "E:"
        Assert-PublisherMajesticHelperDirectory -VolumeMapping $anchor -Create
        $staging = Get-PublisherMajesticBackupPayloadPath `
            -VolumeMapping $anchor -Kind staging
        $outside = Join-Path $TestDrive "outside-staging"
        New-Item -ItemType Directory -Path $outside -Force | Out-Null
        try {
            New-Item -ItemType SymbolicLink -Path $staging -Target $outside `
                -ErrorAction Stop | Out-Null
        } catch {
            Set-ItResult -Skipped -Because "Symbolic links are unavailable"
            return
        }

        {
            Ensure-PublisherMajesticBackupJunction -Config $script:MajesticConfig `
                -AnchorVolume $anchor
        } | Should -Throw "*helper-owned backup path is unsafe*"
        ((Get-Item -LiteralPath $script:MajesticBackupDirectory -Force).Attributes -band
            [IO.FileAttributes]::ReparsePoint) | Should -Be 0
    }

    It "rejects missing, invalid, or ambiguous prefs gameDisk before migration" {
        $prefsPath = Join-Path $script:MajesticProfile `
            "AppData/Roaming/majestic-launcher/prefs.latest.json"
        foreach ($prefs in @('{"selectedProject":"ro"}', '{"gameDisk":"C:"}')) {
            [IO.File]::WriteAllBytes($prefsPath, [Text.Encoding]::UTF8.GetBytes($prefs))
            {
                Invoke-PublisherMajesticSync -Config $script:MajesticConfig `
                    -Manifest $script:MajesticManifest `
                    -VolumeMappings $script:MajesticMappings
            } | Should -Throw "*gameDisk*"
        }
        [IO.File]::WriteAllBytes($prefsPath, $script:MajesticPrefsBytes)
        $ambiguous = @($script:MajesticMappings) + [pscustomobject]@{
            Name = "duplicate"; DriveLetter = "E"; RootPath = (Join-Path $TestDrive "dup")
        }
        New-Item -ItemType Directory -Path $ambiguous[-1].RootPath -Force | Out-Null
        {
            Invoke-PublisherMajesticSync -Config $script:MajesticConfig `
                -Manifest $script:MajesticManifest -VolumeMappings $ambiguous
        } | Should -Throw "*exactly one Publisher volume*"
    }

    It "rejects an oversized or reparse-point source file" {
        $smallLimitPath = Join-Path $TestDrive "oversized-majestic.json"
        [IO.File]::WriteAllBytes($smallLimitPath, [byte[]](1..32))
        {
            Get-PublisherMajesticFileBytes -Path $smallLimitPath `
                -Description "test file" -MaximumBytes 16
        } | Should -Throw "*size limit*"

        $linkPath = Join-Path $TestDrive "majestic-link.json"
        try {
            New-Item -ItemType SymbolicLink -Path $linkPath -Target $smallLimitPath `
                -ErrorAction Stop | Out-Null
        } catch {
            Set-ItResult -Skipped -Because "Symbolic links are unavailable"
            return
        }
        {
            Get-PublisherMajesticFileBytes -Path $linkPath `
                -Description "test file" -MaximumBytes 1MB
        } | Should -Throw "*unsafe*"
    }

    It "rejects backup subdirectories, limits, and a backupMap pointing elsewhere" {
        $isolated = Join-Path $TestDrive "unsafe-backup"
        New-Item -ItemType Directory -Path (Join-Path $isolated "nested") -Force |
            Out-Null
        {
            Get-PublisherMajesticBackupIndex -Path $isolated
        } | Should -Throw "*unsafe entry*"

        $limited = Join-Path $TestDrive "limited-backup"
        New-Item -ItemType Directory -Path $limited -Force | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $limited "large.bin"), [byte[]](1..8))
        {
            Get-PublisherMajesticBackupIndex -Path $limited -MaximumTotalBytes 4
        } | Should -Throw "*size limit*"

        $backupMapPath = Join-Path $script:MajesticProfile `
            "AppData/Roaming/majestic-launcher/backupMap.json"
        $badMap = [ordered]@{
            version = 1
            backupDir = (Join-Path $TestDrive "somewhere-else")
            files = [ordered]@{
                "GTA5.exe" = [ordered]@{
                    size = 5; mtimeNs = "1787644592547527100"
                    finalHash = "60694b13a70d4081"
                }
            }
        } | ConvertTo-Json -Depth 6 -Compress
        [IO.File]::WriteAllBytes($backupMapPath, [Text.Encoding]::UTF8.GetBytes($badMap))
        $anchor = Get-PublisherMajesticAnchorVolume `
            -VolumeMappings $script:MajesticMappings -GameDisk "E:"
        Ensure-PublisherMajesticBackupJunction -Config $script:MajesticConfig `
            -AnchorVolume $anchor | Out-Null
        {
            Get-PublisherMajesticBundleBytes -Config $script:MajesticConfig `
                -ConfigRevision "majestic-revision"
        } | Should -Throw "*another backup directory*"
    }

    It "disabled removes only bundles and preserves backup payload and junction" {
        Invoke-PublisherMajesticSync -Config $script:MajesticConfig `
            -Manifest $script:MajesticManifest -VolumeMappings $script:MajesticMappings
        $payloadPath = Get-PublisherMajesticBackupPayloadPath `
            -VolumeMapping $script:MajesticMappings[0]
        foreach ($mapping in $script:MajesticMappings) {
            foreach ($schemaVersion in @(1, 2)) {
                $path = Get-PublisherMajesticBundlePath -VolumeMapping $mapping `
                    -SchemaVersion $schemaVersion
                New-Item -ItemType Directory -Path (Split-Path $path -Parent) `
                    -Force | Out-Null
                Set-Content -LiteralPath $path -Value "stale"
            }
        }
        $disabled = [pscustomobject]@{
            Present = $true
            Enabled = $false
        }

        Invoke-PublisherMajesticSync -Config $disabled `
            -Manifest $script:MajesticManifest -VolumeMappings $script:MajesticMappings

        foreach ($mapping in $script:MajesticMappings) {
            foreach ($schemaVersion in @(1, 2)) {
                Test-Path -LiteralPath (
                    Get-PublisherMajesticBundlePath -VolumeMapping $mapping `
                        -SchemaVersion $schemaVersion
                ) | Should -BeFalse
            }
        }
        Test-Path -LiteralPath $payloadPath | Should -BeTrue
        ((Get-Item -LiteralPath $script:MajesticBackupDirectory -Force).Attributes -band
            [IO.FileAttributes]::ReparsePoint) | Should -Not -Be 0
    }

    It "cleans a partial bundle write and a retry can reconcile every volume" {
        Mock Get-PublisherMajesticBundleBytes {
            return [Text.Encoding]::UTF8.GetBytes('{"schema_version":2}')
        }
        $script:MajesticExportCalls = 0
        Mock Export-PublisherMajesticBundles {
            $script:MajesticExportCalls++
            if ($script:MajesticExportCalls -eq 1) {
                $path = Get-PublisherMajesticBundlePath `
                    -VolumeMapping $script:MajesticMappings[0]
                New-Item -ItemType Directory -Path (Split-Path $path -Parent) `
                    -Force | Out-Null
                Set-Content -LiteralPath $path -Value "partial"
                throw "injected after first bundle"
            }
            foreach ($mapping in $VolumeMappings) {
                $path = Get-PublisherMajesticBundlePath -VolumeMapping $mapping
                New-Item -ItemType Directory -Path (Split-Path $path -Parent) `
                    -Force | Out-Null
                [IO.File]::WriteAllBytes($path, $BundleBytes)
            }
        }

        Invoke-PublisherMajesticSync -Config $script:MajesticConfig `
            -Manifest $script:MajesticManifest -VolumeMappings $script:MajesticMappings

        foreach ($mapping in $script:MajesticMappings) {
            Test-Path -LiteralPath (
                Get-PublisherMajesticBundlePath -VolumeMapping $mapping
            ) | Should -BeFalse
        }
        Invoke-PublisherMajesticSync -Config $script:MajesticConfig `
            -Manifest $script:MajesticManifest -VolumeMappings $script:MajesticMappings
        foreach ($mapping in $script:MajesticMappings) {
            Test-Path -LiteralPath (
                Get-PublisherMajesticBundlePath -VolumeMapping $mapping
            ) | Should -BeTrue
        }
    }

    It "fails before disconnect when stale bundle cleanup cannot be confirmed" {
        $anchor = Get-PublisherMajesticAnchorVolume `
            -VolumeMappings $script:MajesticMappings -GameDisk "E:"
        Ensure-PublisherMajesticBackupJunction -Config $script:MajesticConfig `
            -AnchorVolume $anchor | Out-Null
        Mock Get-PublisherMajesticBundleBytes { throw "capture failed" }
        Mock Remove-PublisherMajesticBundles { throw "cleanup failed" }

        {
            Invoke-PublisherMajesticSync -Config $script:MajesticConfig `
                -Manifest $script:MajesticManifest `
                -VolumeMappings $script:MajesticMappings
        } | Should -Throw "*stale bundle cleanup failed*"
    }

    It "gracefully closes and then force-stops Majestic Launcher" {
        $process = [pscustomobject]@{ Id = 42; ProcessName = "Majestic Launcher" }
        $process | Add-Member -MemberType ScriptMethod -Name CloseMainWindow `
            -Value { return $true }
        $script:MajesticProcessQueries = 0
        Mock Get-Process {
            $script:MajesticProcessQueries++
            if ($script:MajesticProcessQueries -le 2) { return @($process) }
            return @()
        } -ParameterFilter { $Name -eq "Majestic Launcher" }
        Mock Start-Sleep { }
        Mock Stop-Process { }

        Stop-MajesticLauncherProcesses -GraceSeconds 0

        Should -Invoke Stop-Process -Times 1 -Exactly -ParameterFilter {
            $Id -eq 42 -and $Force
        }
    }
}

Describe "Publisher local disconnect and reconnect" {
    BeforeEach {
        $script:Manifest = [pscustomobject]@{
            schema_version = 1
            config_revision = "0123456789abcdef"
            target_iqn = "iqn.2026-08.lab.games:master"
            portal = [pscustomobject]@{ address = "10.20.40.10"; port = 3260 }
            volumes = @(
                [pscustomobject]@{ name = "ssd"; disk_unique_id = "aaa"; lun = 0 },
                [pscustomobject]@{ name = "hdd"; disk_unique_id = "bbb"; lun = 1 }
            )
        }
        $script:PendingPath = Join-Path $TestDrive "publisher.pending.json"
        Remove-Item -LiteralPath $script:PendingPath -Force -ErrorAction SilentlyContinue
        $script:Session = [pscustomobject]@{ TargetNodeAddress = $script:Manifest.target_iqn }
        $script:Disks = @(
            [pscustomobject]@{ UniqueId = "0xaaa"; Number = 10; IsOffline = $true },
            [pscustomobject]@{ UniqueId = "0xbbb"; Number = 11; IsOffline = $true }
        )
        Mock Get-PublisherSessionDisks { return @($script:Disks) }
        Mock Set-PublisherDisksOffline { }
        Mock Disconnect-IscsiTarget { }
    }

    It "writes pending state before disconnecting exact disks" {
        $script:SessionChecks = 0
        Mock Get-PublisherSession {
            $script:SessionChecks++
            if ($script:SessionChecks -eq 1) { return @($script:Session) }
            return @()
        }

        Invoke-PublisherDisconnect -Manifest $script:Manifest -StatePath $script:PendingPath

        Test-Path -LiteralPath $script:PendingPath | Should -BeTrue
        Should -Invoke Set-PublisherDisksOffline -Times 1 -Exactly
        Should -Invoke Disconnect-IscsiTarget -Times 1 -Exactly
        $pending = Get-Content -LiteralPath $script:PendingPath -Raw | ConvertFrom-Json
        $pending.config_revision | Should -Be $script:Manifest.config_revision
    }

    It "does not create pending state when NAA validation fails" {
        $script:Disks[1].UniqueId = "wrong"
        Mock Get-PublisherSession { return @($script:Session) }

        { Invoke-PublisherDisconnect -Manifest $script:Manifest -StatePath $script:PendingPath } | Should -Throw

        Test-Path -LiteralPath $script:PendingPath | Should -BeFalse
        Should -Invoke Disconnect-IscsiTarget -Times 0 -Exactly
    }

    It "reconnects non-persistently, validates all NAA, then removes pending" {
        Save-PublisherPending -Path $script:PendingPath -Manifest $script:Manifest
        $script:SessionChecks = 0
        Mock Ensure-PublisherPortal { }
        Mock Wait-PublisherTargetDiscovery {
            return [pscustomobject]@{ NodeAddress = $script:Manifest.target_iqn }
        }
        Mock Connect-IscsiTarget { }
        Mock Get-PublisherSession {
            $script:SessionChecks++
            if ($script:SessionChecks -eq 1) { return @() }
            return @($script:Session)
        }
        Mock Set-Disk { }
        Mock Get-Disk {
            param($Number)
            return [pscustomobject]@{ Number = $Number; IsOffline = $false }
        }

        Invoke-PublisherReconnect -Manifest $script:Manifest -StatePath $script:PendingPath

        Test-Path -LiteralPath $script:PendingPath | Should -BeFalse
        Should -Invoke Connect-IscsiTarget -Times 1 -Exactly -ParameterFilter {
            $IsPersistent -eq $false -and $NodeAddress -eq $script:Manifest.target_iqn
        }
        Should -Invoke Set-Disk -Times 2 -Exactly -ParameterFilter { $IsOffline -eq $false }
    }

    It "rejects a different manifest revision while pending" {
        Save-PublisherPending -Path $script:PendingPath -Manifest $script:Manifest
        $script:Manifest.config_revision = "fedcba9876543210"

        { Invoke-PublisherReconnect -Manifest $script:Manifest -StatePath $script:PendingPath } | Should -Throw

        Test-Path -LiteralPath $script:PendingPath | Should -BeTrue
    }

    It "uses pending state to recover a still-connected partial disconnect" {
        Save-PublisherPending -Path $script:PendingPath -Manifest $script:Manifest
        Mock Ensure-PublisherPortal { }
        Mock Wait-PublisherTargetDiscovery { throw "discovery should not run" }
        Mock Connect-IscsiTarget { }
        Mock Get-PublisherSession { return @($script:Session) }
        Mock Set-Disk { }
        Mock Get-Disk {
            param($Number)
            return [pscustomobject]@{ Number = $Number; IsOffline = $false }
        }

        Invoke-PublisherReconnect -Manifest $script:Manifest -StatePath $script:PendingPath

        Test-Path -LiteralPath $script:PendingPath | Should -BeFalse
        Should -Invoke Ensure-PublisherPortal -Times 0 -Exactly
        Should -Invoke Wait-PublisherTargetDiscovery -Times 0 -Exactly
        Should -Invoke Connect-IscsiTarget -Times 0 -Exactly
        Should -Invoke Set-Disk -Times 2 -Exactly -ParameterFilter { $IsOffline -eq $false }
    }

    It "keeps pending state and offline disks when discovery times out" {
        Save-PublisherPending -Path $script:PendingPath -Manifest $script:Manifest
        Mock Ensure-PublisherPortal { }
        Mock Get-PublisherSession { return @() }
        Mock Wait-PublisherTargetDiscovery { throw "target discovery timed out" }
        Mock Connect-IscsiTarget { }
        Mock Set-Disk { }

        {
            Invoke-PublisherReconnect -Manifest $script:Manifest -StatePath $script:PendingPath
        } | Should -Throw "*target discovery timed out*"

        Test-Path -LiteralPath $script:PendingPath | Should -BeTrue
        @($script:Disks | Where-Object { -not $_.IsOffline }).Count | Should -Be 0
        Should -Invoke Connect-IscsiTarget -Times 0 -Exactly
        Should -Invoke Set-Disk -Times 0 -Exactly
    }
}

Describe "Publisher Epic Games manifest bundles" {
    BeforeAll {
        function New-PublisherTestEgsItem {
            param(
                [Parameter(Mandatory = $true)][string]$AppName,
                [Parameter(Mandatory = $true)][string]$Guid,
                [Parameter(Mandatory = $true)][string]$VolumeRoot,
                [Parameter(Mandatory = $true)][string[]]$InstallTags,
                [switch]$Utf8Bom,
                [switch]$OmitComponent
            )
            $installLocation = Join-Path $VolumeRoot $AppName
            $egstore = Join-Path $installLocation ".egstore"
            New-Item -ItemType Directory -Path $egstore -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $installLocation "$AppName.exe") -Value "exe"
            [IO.File]::WriteAllBytes((Join-Path $egstore "$Guid.manifest"), [byte[]](1, 2, 3))
            if (-not $OmitComponent) {
                @{
                    AppName = $AppName
                    CatalogItemId = "catalog-$AppName"
                    CatalogNamespace = "namespace-$AppName"
                } | ConvertTo-Json | Set-Content `
                    -LiteralPath (Join-Path $egstore "$Guid.mancpn")
            }
            $item = [ordered]@{
                AppName = $AppName
                AppVersionString = "build-$AppName"
                InstallationGuid = $Guid
                InstallLocation = $installLocation
                ManifestLocation = $egstore
                StagingLocation = (Join-Path $egstore "bps")
                InstallTags = $InstallTags
                LaunchExecutable = "$AppName.exe"
            }
            $path = Join-Path $script:EgsManifestDirectory "$Guid.item"
            $json = $item | ConvertTo-Json -Depth 5
            $encoding = New-Object Text.UTF8Encoding($Utf8Bom.IsPresent)
            $bytes = [byte[]]@($encoding.GetPreamble()) + $encoding.GetBytes($json)
            [IO.File]::WriteAllBytes($path, $bytes)
            return $path
        }

        function New-PublisherTestLauncherEntry {
            param(
                [Parameter(Mandatory = $true)][string]$AppName,
                [Parameter(Mandatory = $true)][string]$VolumeRoot,
                [string]$Version = ""
            )
            if ([string]::IsNullOrWhiteSpace($Version)) { $Version = "build-$AppName" }
            return [ordered]@{
                InstallLocation = (Join-Path $VolumeRoot $AppName)
                NamespaceId = "namespace-$AppName"
                ItemId = "item-$AppName"
                ArtifactId = "artifact-$AppName"
                AppVersion = $Version
                AppName = $AppName
            }
        }

        function Set-PublisherTestLauncherInstalled {
            param(
                [Parameter(Mandatory = $true)][string]$Path,
                [Parameter(Mandatory = $true)]$InstallationList
            )
            [ordered]@{ InstallationList = @($InstallationList) } |
                ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path
        }
    }

    BeforeEach {
        $script:EgsManifestDirectory = Join-Path $TestDrive "ProgramData-Manifests"
        Remove-Item -LiteralPath $script:EgsManifestDirectory -Recurse -Force `
            -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Path $script:EgsManifestDirectory -Force | Out-Null
        $script:EgsLauncherInstalledPath = Join-Path $TestDrive "LauncherInstalled.dat"
        Remove-Item -LiteralPath $script:EgsLauncherInstalledPath -Force `
            -ErrorAction SilentlyContinue
        $script:EgsSharedInstallDbPath = Join-Path $TestDrive `
            "EpicOnlineServicesShared/InstallHelper/InstalledItems"
        Remove-Item -LiteralPath $script:EgsSharedInstallDbPath -Recurse -Force `
            -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Path $script:EgsSharedInstallDbPath `
            -Force | Out-Null
        foreach ($appName in @("GTA5", "Fortnite", "GTA5Enhanced")) {
            [IO.File]::WriteAllBytes(
                (Join-Path $script:EgsSharedInstallDbPath "$appName.json"),
                [Text.Encoding]::UTF8.GetBytes(
                    "{`"AppName`":`"$appName`",`"State`":`"Installed`"}"
                )
            )
        }
        $script:EgsMappings = @(
            [pscustomobject]@{ Name = "ssd"; RootPath = (Join-Path $TestDrive "ssd"); Disk = $null },
            [pscustomobject]@{ Name = "hdd"; RootPath = (Join-Path $TestDrive "hdd"); Disk = $null },
            [pscustomobject]@{ Name = "bonus"; RootPath = (Join-Path $TestDrive "bonus"); Disk = $null }
        )
        foreach ($mapping in $script:EgsMappings) {
            Remove-Item -LiteralPath $mapping.RootPath -Recurse -Force `
                -ErrorAction SilentlyContinue
            New-Item -ItemType Directory -Path $mapping.RootPath -Force | Out-Null
        }
        $script:EgsManifest = [pscustomobject]@{
            config_revision = "0123456789abcdef"
        }
    }

    It "writes exact manifests and safe registrations for three games and volumes" {
        $fortniteId = "6CBCB32C02D40E72A7D7C61F8AB8A4A"
        New-PublisherTestEgsItem -AppName "GTA5" `
            -Guid "11111111111111111111111111111111" `
            -VolumeRoot $script:EgsMappings[0].RootPath -InstallTags @("default") | Out-Null
        New-PublisherTestEgsItem -AppName "GTA5Enhanced" `
            -Guid "22222222222222222222222222222222" `
            -VolumeRoot $script:EgsMappings[0].RootPath -InstallTags @("default") | Out-Null
        New-PublisherTestEgsItem -AppName "Fortnite" `
            -Guid $fortniteId `
            -VolumeRoot $script:EgsMappings[1].RootPath `
            -InstallTags @("chunk0", "chunk10", "chunk10optional") `
            -Utf8Bom -OmitComponent | Out-Null
        Set-PublisherTestLauncherInstalled -Path $script:EgsLauncherInstalledPath `
            -InstallationList @(
                New-PublisherTestLauncherEntry -AppName "GTA5" `
                    -VolumeRoot $script:EgsMappings[0].RootPath
                New-PublisherTestLauncherEntry -AppName "GTA5Enhanced" `
                    -VolumeRoot $script:EgsMappings[0].RootPath
                New-PublisherTestLauncherEntry -AppName "Fortnite" `
                    -VolumeRoot $script:EgsMappings[1].RootPath
            )
        foreach ($mapping in $script:EgsMappings) {
            $metadata = Join-Path $mapping.RootPath ".iscsi-reset"
            New-Item -ItemType Directory -Path $metadata -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $metadata "egs-manifests.v1.json") `
                -Value "legacy"
        }

        Export-PublisherEgsBundles -Manifest $script:EgsManifest `
            -VolumeMappings $script:EgsMappings -ManifestDirectory $script:EgsManifestDirectory `
            -LauncherInstalledPath $script:EgsLauncherInstalledPath

        $ssd = Get-Content -LiteralPath (Join-Path $script:EgsMappings[0].RootPath `
            ".iscsi-reset/egs-manifests.v2.json") -Raw | ConvertFrom-Json
        $hdd = Get-Content -LiteralPath (Join-Path $script:EgsMappings[1].RootPath `
            ".iscsi-reset/egs-manifests.v2.json") -Raw | ConvertFrom-Json
        $bonus = Get-Content -LiteralPath (Join-Path $script:EgsMappings[2].RootPath `
            ".iscsi-reset/egs-manifests.v2.json") -Raw | ConvertFrom-Json

        @($ssd.manifests).Count | Should -Be 2
        @($hdd.manifests).Count | Should -Be 1
        @($bonus.manifests).Count | Should -Be 0
        $fortniteBytes = [Convert]::FromBase64String($hdd.manifests[0].payload_base64)
        [BitConverter]::ToString($fortniteBytes[0..2]) | Should -Be "EF-BB-BF"
        $fortnite = ConvertFrom-EgsJsonBytes -Bytes $fortniteBytes
        $fortnite.InstallationGuid | Should -Be $fortniteId
        @($fortnite.InstallTags) | Should -Be @("chunk0", "chunk10", "chunk10optional")
        $hdd.manifests[0].launcher_registration.app_name | Should -Be "Fortnite"
        $hdd.manifests[0].launcher_registration.PSObject.Properties.Name |
            Sort-Object | Should -Be @(
                "app_name", "app_version", "artifact_id", "install_location", "item_id",
                "namespace_id"
            )
        $hdd.manifests[0].binary_manifest_sha256 | Should -Match "^[0-9a-f]{64}$"
        $hdd.manifests[0].mancpn_sha256 | Should -BeNullOrEmpty
        foreach ($mapping in $script:EgsMappings) {
            Test-Path -LiteralPath (Join-Path $mapping.RootPath `
                ".iscsi-reset/egs-manifests.v1.json") | Should -BeFalse
        }
    }

    It "writes one exact aggressive state archive for an ordered three-volume release" {
        $programDataPath = Join-Path $TestDrive "EpicGamesLauncher/Data"
        $script:EgsManifestDirectory = Join-Path $programDataPath "Manifests"
        New-Item -ItemType Directory -Path $script:EgsManifestDirectory -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $programDataPath "Catalog") `
            -Force | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $programDataPath "Catalog/unknown.bin"), `
            [byte[]](9, 8, 7, 6))
        New-PublisherTestEgsItem -AppName "GTA5" `
            -Guid "11111111111111111111111111111111" `
            -VolumeRoot $script:EgsMappings[0].RootPath -InstallTags @("default") | Out-Null
        New-PublisherTestEgsItem -AppName "Fortnite" `
            -Guid "22222222222222222222222222222222" `
            -VolumeRoot $script:EgsMappings[1].RootPath -InstallTags @("chunk0") | Out-Null
        New-PublisherTestEgsItem -AppName "GTA5Enhanced" `
            -Guid "33333333333333333333333333333333" `
            -VolumeRoot $script:EgsMappings[2].RootPath -InstallTags @("default") | Out-Null
        [ordered]@{
            InstallationList = @(
                New-PublisherTestLauncherEntry -AppName "GTA5" `
                    -VolumeRoot $script:EgsMappings[0].RootPath
                New-PublisherTestLauncherEntry -AppName "Fortnite" `
                    -VolumeRoot $script:EgsMappings[1].RootPath
                New-PublisherTestLauncherEntry -AppName "GTA5Enhanced" `
                    -VolumeRoot $script:EgsMappings[2].RootPath
            )
            UnknownTopLevel = [ordered]@{ machine = "publisher"; value = 42 }
        } | ConvertTo-Json -Depth 8 | Set-Content $script:EgsLauncherInstalledPath
        foreach ($mapping in $script:EgsMappings) {
            $metadata = Join-Path $mapping.RootPath ".iscsi-reset"
            New-Item -ItemType Directory -Path $metadata -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $metadata "egs-manifests.v3.json") `
                -Value "legacy-v3"
            Set-Content -LiteralPath (Join-Path $metadata "egs-programdata.v3.zip") `
                -Value "legacy-v3"
            Set-Content -LiteralPath (Join-Path $metadata `
                "egs-programdata.v3.index.json") -Value "legacy-v3"
        }

        $result = Export-PublisherEgsAggressiveBundles -Manifest $script:EgsManifest `
            -VolumeMappings $script:EgsMappings `
            -ManifestDirectory $script:EgsManifestDirectory `
            -ProgramDataPath $programDataPath `
            -LauncherInstalledPath $script:EgsLauncherInstalledPath `
            -SharedInstallDbPath $script:EgsSharedInstallDbPath

        $result.FileCount | Should -BeGreaterThan 7
        $result.SharedInstallDbFileCount | Should -Be 3
        foreach ($mapping in $script:EgsMappings) {
            $bundlePath = Join-Path $mapping.RootPath `
                ".iscsi-reset/egs-manifests.v4.json"
            Test-Path -LiteralPath $bundlePath | Should -BeTrue
            $bundle = Get-Content -LiteralPath $bundlePath -Raw | ConvertFrom-Json
            $bundle.schema_version | Should -Be 4
            @($bundle.publisher_volume_names) | Should -Be @("ssd", "hdd", "bonus")
            $bundle.archive.anchor_volume | Should -Be "ssd"
            foreach ($version in @(1, 2, 3)) {
                Test-Path -LiteralPath (Join-Path $mapping.RootPath `
                    ".iscsi-reset/egs-manifests.v$version.json") | Should -BeFalse
            }
            Test-Path -LiteralPath (Join-Path $mapping.RootPath `
                ".iscsi-reset/egs-programdata.v3.zip") | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $mapping.RootPath `
                ".iscsi-reset/egs-programdata.v3.index.json") | Should -BeFalse
        }
        $anchorMetadata = Join-Path $script:EgsMappings[0].RootPath ".iscsi-reset"
        $archivePath = Join-Path $anchorMetadata "egs-state.v4.zip"
        $indexPath = Join-Path $anchorMetadata "egs-state.v4.index.json"
        Test-Path -LiteralPath $archivePath | Should -BeTrue
        Test-Path -LiteralPath $indexPath | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:EgsMappings[1].RootPath `
            ".iscsi-reset/egs-state.v4.zip") | Should -BeFalse
        $index = Get-Content -LiteralPath $indexPath -Raw | ConvertFrom-Json
        $index.schema_version | Should -Be 2
        @($index.files.relative_path) |
            Should -Contain "EpicGamesLauncher/Data/Catalog/unknown.bin"
        @($index.files.relative_path) |
            Should -Contain "UnrealEngineLauncher/LauncherInstalled.dat"
        @($index.files.relative_path) | Should -Contain `
            "EpicOnlineServicesShared/InstallHelper/InstalledItems/Fortnite.json"
        {
            Get-PublisherEgsAggressiveIndexData -ProgramDataPath $programDataPath `
                -LauncherInstalledPath $script:EgsLauncherInstalledPath `
                -SharedInstallDbPath $script:EgsSharedInstallDbPath `
                -MaximumFileCount 1
        } | Should -Throw "*file count safety limit*"
    }

    It "rejects an empty shared installation database" {
        $programDataPath = Join-Path $TestDrive "empty-shared/EpicGamesLauncher/Data"
        $launcherPath = Join-Path $TestDrive "empty-shared/LauncherInstalled.dat"
        $sharedPath = Join-Path $TestDrive "empty-shared/Shared/InstalledItems"
        New-Item -ItemType Directory -Path $programDataPath -Force | Out-Null
        New-Item -ItemType Directory -Path $sharedPath -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $programDataPath "data.bin") -Value "data"
        Set-Content -LiteralPath $launcherPath -Value '{"InstallationList":[]}'

        {
            Get-PublisherEgsAggressiveIndexData -ProgramDataPath $programDataPath `
                -LauncherInstalledPath $launcherPath -SharedInstallDbPath $sharedPath
        } | Should -Throw "*shared installation database is empty*"
    }

    It "blocks while InstallHelper uses the exact shared installation database" {
        Mock Get-EgsSharedInstallHelperProcesses { return @([pscustomobject]@{ Id = 42 }) }
        Mock Start-Sleep { }

        {
            Wait-EgsSharedInstallDbIdle -InstallDbPath $script:EgsSharedInstallDbPath `
                -TimeoutSeconds 0
        } | Should -Throw "*shared installation database is still in use*"
    }

    It "uses item-only fallback for missing, duplicate, and mismatched registrations" {
        New-PublisherTestEgsItem -AppName "GTA5" `
            -Guid "10101010101010101010101010101010" `
            -VolumeRoot $script:EgsMappings[0].RootPath -InstallTags @("default") | Out-Null
        New-PublisherTestEgsItem -AppName "Fortnite" `
            -Guid "20202020202020202020202020202020" `
            -VolumeRoot $script:EgsMappings[1].RootPath -InstallTags @("chunk0") | Out-Null
        New-PublisherTestEgsItem -AppName "GTA5Enhanced" `
            -Guid "30303030303030303030303030303030" `
            -VolumeRoot $script:EgsMappings[1].RootPath -InstallTags @("default") | Out-Null
        Set-PublisherTestLauncherInstalled -Path $script:EgsLauncherInstalledPath `
            -InstallationList @(
                New-PublisherTestLauncherEntry -AppName "Fortnite" `
                    -VolumeRoot $script:EgsMappings[1].RootPath
                New-PublisherTestLauncherEntry -AppName "Fortnite" `
                    -VolumeRoot $script:EgsMappings[1].RootPath
                New-PublisherTestLauncherEntry -AppName "GTA5Enhanced" `
                    -VolumeRoot $script:EgsMappings[1].RootPath -Version "wrong-build"
            )

        Export-PublisherEgsBundles -Manifest $script:EgsManifest `
            -VolumeMappings $script:EgsMappings -ManifestDirectory $script:EgsManifestDirectory `
            -LauncherInstalledPath $script:EgsLauncherInstalledPath

        $entries = @($script:EgsMappings | ForEach-Object {
            (Get-Content -LiteralPath (Join-Path $_.RootPath `
                ".iscsi-reset/egs-manifests.v2.json") -Raw | ConvertFrom-Json).manifests
        })
        $entries.Count | Should -Be 3
        @($entries | Where-Object { $null -ne $_.launcher_registration }).Count |
            Should -Be 0
    }

    It "warns but exports exact incomplete installation state" {
        $guid = "40404040404040404040404040404040"
        $itemPath = New-PublisherTestEgsItem -AppName "Fortnite" -Guid $guid `
            -VolumeRoot $script:EgsMappings[1].RootPath -InstallTags @("chunk0")
        $item = Get-Content -LiteralPath $itemPath -Raw | ConvertFrom-Json
        $item | Add-Member -NotePropertyName bIsIncompleteInstall -NotePropertyValue $true
        $item | Add-Member -NotePropertyName bNeedsValidation -NotePropertyValue $true
        $item | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $itemPath
        $egstore = Join-Path (Join-Path $script:EgsMappings[1].RootPath "Fortnite") ".egstore"
        New-Item -ItemType Directory -Path (Join-Path $egstore "bps") -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $egstore "Pending") -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $egstore "bps/staging.dat") -Value "pending"
        Set-Content -LiteralPath (Join-Path $egstore "Pending/chunk.dat") -Value "pending"

        Export-PublisherEgsBundles -Manifest $script:EgsManifest `
            -VolumeMappings $script:EgsMappings -ManifestDirectory $script:EgsManifestDirectory `
            -LauncherInstalledPath $script:EgsLauncherInstalledPath

        $bundle = Get-Content -LiteralPath (Join-Path $script:EgsMappings[1].RootPath `
            ".iscsi-reset/egs-manifests.v2.json") -Raw | ConvertFrom-Json
        @($bundle.manifests[0].state_warnings | Sort-Object) | Should -Be @(
            "bps_nonempty", "item_incomplete", "item_needs_validation", "pending_nonempty"
        )
    }

    It "treats an invalid LauncherInstalled.dat as item-only fallback" {
        New-PublisherTestEgsItem -AppName "GTA5" `
            -Guid "50505050505050505050505050505050" `
            -VolumeRoot $script:EgsMappings[0].RootPath -InstallTags @("default") | Out-Null
        Set-Content -LiteralPath $script:EgsLauncherInstalledPath -Value "not-json"

        Export-PublisherEgsBundles -Manifest $script:EgsManifest `
            -VolumeMappings $script:EgsMappings -ManifestDirectory $script:EgsManifestDirectory `
            -LauncherInstalledPath $script:EgsLauncherInstalledPath

        $bundle = Get-Content -LiteralPath (Join-Path $script:EgsMappings[0].RootPath `
            ".iscsi-reset/egs-manifests.v2.json") -Raw | ConvertFrom-Json
        $bundle.manifests[0].launcher_registration | Should -BeNullOrEmpty
    }

    It "rejects an unsafe installation identifier before writing any volume bundle" {
        New-PublisherTestEgsItem -AppName "Fortnite" `
            -Guid "33333333333333333333333333333333" `
            -VolumeRoot $script:EgsMappings[0].RootPath -InstallTags @("chunk0") | Out-Null
        $path = Join-Path $script:EgsManifestDirectory "33333333333333333333333333333333.item"
        $item = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $item.InstallationGuid = "not-a-guid"
        $item | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path

        {
            Export-PublisherEgsBundles -Manifest $script:EgsManifest `
                -VolumeMappings $script:EgsMappings -ManifestDirectory $script:EgsManifestDirectory
        } | Should -Throw "*invalid Epic installation identifier*"

        foreach ($mapping in $script:EgsMappings) {
            Test-Path -LiteralPath (Join-Path $mapping.RootPath `
                ".iscsi-reset/egs-manifests.v2.json") | Should -BeFalse
        }
    }

    It "reconciles every volume after a partial bundle write" {
        New-PublisherTestEgsItem -AppName "GTA5" `
            -Guid "44444444444444444444444444444444" `
            -VolumeRoot $script:EgsMappings[0].RootPath -InstallTags @("default") | Out-Null
        New-PublisherTestEgsItem -AppName "Fortnite" `
            -Guid "55555555555555555555555555555555" `
            -VolumeRoot $script:EgsMappings[1].RootPath -InstallTags @("chunk0") | Out-Null
        $script:RealPublisherBundleWriter = ${function:Write-PublisherEgsBundleAtomic}
        $script:PublisherBundleWriteCount = 0
        $script:InjectPublisherBundleFailure = $true
        Mock Write-PublisherEgsBundleAtomic {
            $script:PublisherBundleWriteCount++
            if ($script:InjectPublisherBundleFailure -and
                $script:PublisherBundleWriteCount -eq 2) {
                throw "injected after first bundle write"
            }
            & $script:RealPublisherBundleWriter -Path $Path -Bundle $Bundle
        }

        {
            Export-PublisherEgsBundles -Manifest $script:EgsManifest `
                -VolumeMappings $script:EgsMappings -ManifestDirectory $script:EgsManifestDirectory
        } | Should -Throw "*after first bundle write*"
        Test-Path -LiteralPath (Join-Path $script:EgsMappings[0].RootPath `
            ".iscsi-reset/egs-manifests.v2.json") | Should -BeTrue

        $script:InjectPublisherBundleFailure = $false
        Export-PublisherEgsBundles -Manifest $script:EgsManifest `
            -VolumeMappings $script:EgsMappings -ManifestDirectory $script:EgsManifestDirectory

        foreach ($mapping in $script:EgsMappings) {
            Assert-PublisherEgsBundle -Path (Join-Path $mapping.RootPath `
                ".iscsi-reset/egs-manifests.v2.json") `
                -ConfigRevision $script:EgsManifest.config_revision -VolumeName $mapping.Name `
                -VolumeRoot $mapping.RootPath
        }
    }

    It "reconciles every volume after partial legacy bundle removal" {
        New-PublisherTestEgsItem -AppName "GTA5" `
            -Guid "60606060606060606060606060606060" `
            -VolumeRoot $script:EgsMappings[0].RootPath -InstallTags @("default") | Out-Null
        foreach ($mapping in $script:EgsMappings) {
            $metadata = Join-Path $mapping.RootPath ".iscsi-reset"
            New-Item -ItemType Directory -Path $metadata -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $metadata "egs-manifests.v1.json") `
                -Value "legacy"
        }
        $script:RealLegacyBundleRemover = ${function:Remove-PublisherEgsLegacyBundle}
        $script:LegacyRemovalCount = 0
        $script:InjectLegacyRemovalFailure = $true
        Mock Remove-PublisherEgsLegacyBundle {
            $script:LegacyRemovalCount++
            if ($script:InjectLegacyRemovalFailure -and $script:LegacyRemovalCount -eq 2) {
                throw "injected after first legacy removal"
            }
            & $script:RealLegacyBundleRemover -Path $Path
        }

        {
            Export-PublisherEgsBundles -Manifest $script:EgsManifest `
                -VolumeMappings $script:EgsMappings `
                -ManifestDirectory $script:EgsManifestDirectory
        } | Should -Throw "*after first legacy removal*"
        foreach ($mapping in $script:EgsMappings) {
            Test-Path -LiteralPath (Join-Path $mapping.RootPath `
                ".iscsi-reset/egs-manifests.v2.json") | Should -BeTrue
        }

        $script:InjectLegacyRemovalFailure = $false
        Export-PublisherEgsBundles -Manifest $script:EgsManifest `
            -VolumeMappings $script:EgsMappings `
            -ManifestDirectory $script:EgsManifestDirectory
        foreach ($mapping in $script:EgsMappings) {
            Test-Path -LiteralPath (Join-Path $mapping.RootPath `
                ".iscsi-reset/egs-manifests.v1.json") | Should -BeFalse
        }
    }

    It "does not create pending state or offline disks when bundle export fails" {
        $manifest = [pscustomobject]@{
            schema_version = 1
            config_revision = "0123456789abcdef"
            target_iqn = "iqn.2026-08.lab.games:master"
            volumes = @([pscustomobject]@{ name = "ssd"; disk_unique_id = "aaa"; lun = 0 })
        }
        $pendingPath = Join-Path $TestDrive "publisher.pending.json"
        $session = [pscustomobject]@{ TargetNodeAddress = $manifest.target_iqn }
        $disk = [pscustomobject]@{ UniqueId = "aaa"; Number = 10; IsOffline = $false }
        Mock Get-PublisherSession { return @($session) }
        Mock Get-PublisherSessionDisks { return @($disk) }
        Mock Stop-EgsLauncherProcesses { }
        Mock Get-PublisherEgsVolumeMappings {
            return @([pscustomobject]@{ Name = "ssd"; RootPath = "S:\"; Disk = $disk })
        }
        Mock Export-PublisherEgsBundles { throw "injected after first bundle write" }
        Mock Set-PublisherDisksOffline { }
        Mock Disconnect-IscsiTarget { }

        {
            Invoke-PublisherDisconnect -Manifest $manifest -StatePath $pendingPath `
                -EgsSyncEnabled $true -EpicManifestDirectory $script:EgsManifestDirectory
        } | Should -Throw "*after first bundle write*"

        Test-Path -LiteralPath $pendingPath | Should -BeFalse
        Should -Invoke Set-PublisherDisksOffline -Times 0 -Exactly
        Should -Invoke Disconnect-IscsiTarget -Times 0 -Exactly
    }

    It "parses explicit enabled and disabled local sync configuration" {
        $path = Join-Path $TestDrive "egs-sync.json"
        @{ schema_version = 1; enabled = $true } | ConvertTo-Json | Set-Content $path
        Get-EgsManifestSyncEnabled -Path $path | Should -BeTrue
        @{ schema_version = 1; enabled = $false } | ConvertTo-Json | Set-Content $path
        Get-EgsManifestSyncEnabled -Path $path | Should -BeFalse
        Remove-Item -LiteralPath $path
        Get-EgsManifestSyncEnabled -Path $path | Should -BeFalse
    }

    It "parses schema 2 aggressive mode while preserving schema 1 compatibility" {
        $path = Join-Path $TestDrive "egs-sync-v2.json"
        @{ schema_version = 2; mode = "aggressive" } | ConvertTo-Json | Set-Content $path
        Get-EgsManifestSyncMode -Path $path | Should -Be "Aggressive"
        Get-EgsManifestSyncEnabled -Path $path | Should -BeTrue
        @{ schema_version = 2; mode = "enabled" } | ConvertTo-Json | Set-Content $path
        Get-EgsManifestSyncMode -Path $path | Should -Be "Enabled"
    }
}
