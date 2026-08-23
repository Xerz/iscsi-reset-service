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
    }

    BeforeEach {
        $script:EgsManifestDirectory = Join-Path $TestDrive "ProgramData-Manifests"
        Remove-Item -LiteralPath $script:EgsManifestDirectory -Recurse -Force `
            -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Path $script:EgsManifestDirectory -Force | Out-Null
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

    It "writes exact GTA and Fortnite manifests to arbitrary three-volume bundles" {
        $fortniteId = "6CBCB32C02D40E72A7D7C61F8AB8A4A"
        New-PublisherTestEgsItem -AppName "GTA5" `
            -Guid "11111111111111111111111111111111" `
            -VolumeRoot $script:EgsMappings[0].RootPath -InstallTags @("default") | Out-Null
        New-PublisherTestEgsItem -AppName "Fortnite" `
            -Guid $fortniteId `
            -VolumeRoot $script:EgsMappings[1].RootPath `
            -InstallTags @("chunk0", "chunk10", "chunk10optional") `
            -Utf8Bom -OmitComponent | Out-Null

        Export-PublisherEgsBundles -Manifest $script:EgsManifest `
            -VolumeMappings $script:EgsMappings -ManifestDirectory $script:EgsManifestDirectory

        $ssd = Get-Content -LiteralPath (Join-Path $script:EgsMappings[0].RootPath `
            ".iscsi-reset/egs-manifests.v1.json") -Raw | ConvertFrom-Json
        $hdd = Get-Content -LiteralPath (Join-Path $script:EgsMappings[1].RootPath `
            ".iscsi-reset/egs-manifests.v1.json") -Raw | ConvertFrom-Json
        $bonus = Get-Content -LiteralPath (Join-Path $script:EgsMappings[2].RootPath `
            ".iscsi-reset/egs-manifests.v1.json") -Raw | ConvertFrom-Json

        @($ssd.manifests).Count | Should -Be 1
        @($hdd.manifests).Count | Should -Be 1
        @($bonus.manifests).Count | Should -Be 0
        $fortniteBytes = [Convert]::FromBase64String($hdd.manifests[0].payload_base64)
        [BitConverter]::ToString($fortniteBytes[0..2]) | Should -Be "EF-BB-BF"
        $fortnite = ConvertFrom-EgsJsonBytes -Bytes $fortniteBytes
        $fortnite.InstallationGuid | Should -Be $fortniteId
        @($fortnite.InstallTags) | Should -Be @("chunk0", "chunk10", "chunk10optional")
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
                ".iscsi-reset/egs-manifests.v1.json") | Should -BeFalse
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
            ".iscsi-reset/egs-manifests.v1.json") | Should -BeTrue

        $script:InjectPublisherBundleFailure = $false
        Export-PublisherEgsBundles -Manifest $script:EgsManifest `
            -VolumeMappings $script:EgsMappings -ManifestDirectory $script:EgsManifestDirectory

        foreach ($mapping in $script:EgsMappings) {
            Assert-PublisherEgsBundle -Path (Join-Path $mapping.RootPath `
                ".iscsi-reset/egs-manifests.v1.json") `
                -ConfigRevision $script:EgsManifest.config_revision -VolumeName $mapping.Name
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
}
