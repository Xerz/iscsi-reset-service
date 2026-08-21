BeforeAll {
    $script:PublisherScriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) "Publish-IscsiRelease.ps1"
    . $script:PublisherScriptPath -NoMain
    foreach ($name in @(
        "Get-IscsiSession", "Get-IscsiTargetPortal", "New-IscsiTargetPortal",
        "Disconnect-IscsiTarget", "Update-IscsiTarget"
    )) {
        if ($null -eq (Get-Command $name -ErrorAction SilentlyContinue)) {
            Set-Item -Path "function:$name" -Value { }
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
        Mock Update-IscsiTarget { }
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
        Mock Update-IscsiTarget { }
        Mock Connect-IscsiTarget { }
        Mock Get-PublisherSession { return @($script:Session) }
        Mock Set-Disk { }
        Mock Get-Disk {
            param($Number)
            return [pscustomobject]@{ Number = $Number; IsOffline = $false }
        }

        Invoke-PublisherReconnect -Manifest $script:Manifest -StatePath $script:PendingPath

        Test-Path -LiteralPath $script:PendingPath | Should -BeFalse
        Should -Invoke Connect-IscsiTarget -Times 0 -Exactly
        Should -Invoke Set-Disk -Times 2 -Exactly -ParameterFilter { $IsOffline -eq $false }
    }
}
