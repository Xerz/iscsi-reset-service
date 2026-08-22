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
