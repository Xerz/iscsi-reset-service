BeforeAll {
    $script:PublisherScriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) "Publish-IscsiRelease.ps1"
    . $script:PublisherScriptPath -NoMain
    if ($null -eq (Get-Command Disconnect-IscsiTarget -ErrorAction SilentlyContinue)) {
        function Disconnect-IscsiTarget { }
    }
    if ($null -eq (Get-Command Update-IscsiTarget -ErrorAction SilentlyContinue)) {
        function Update-IscsiTarget { }
    }
    if ($null -eq (Get-Command Connect-IscsiTarget -ErrorAction SilentlyContinue)) {
        function Connect-IscsiTarget {
            param(
                [string]$NodeAddress,
                [string]$TargetPortalAddress,
                [int]$TargetPortalPortNumber,
                [bool]$IsPersistent,
                [bool]$IsMultipathEnabled,
                [string]$AuthenticationType
            )
        }
    }
    if ($null -eq (Get-Command Set-Disk -ErrorAction SilentlyContinue)) {
        function Set-Disk { }
    }
}

Describe "Publisher disk safety" {
    It "normalizes only case, whitespace, and the optional 0x prefix" {
        Normalize-PublisherDiskId " 0x65 89CF " | Should -Be "6589cf"
        Normalize-PublisherDiskId "EUI.001" | Should -Be "eui.001"
    }

    It "does not contain destructive provisioning commands" {
        $source = Get-Content -LiteralPath $script:PublisherScriptPath -Raw
        $source | Should -Not -Match "(?im)^\s*(Initialize-Disk|Format-Volume|Clear-Disk|New-Partition)\b"
    }

    It "rejects the complete disk set before any mutation when an NAA is absent" {
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
}

Describe "Publisher reconnect behavior" {
    BeforeEach {
        $script:Publisher = [pscustomobject]@{
            target_iqn = "iqn.2026-08.lab.games:master"
            portal = [pscustomobject]@{ address = "10.20.40.10"; port = 3260 }
        }
        $script:ExpectedVolumes = @(
            [pscustomobject]@{ name = "ssd"; disk_unique_id = "aaa"; lun = 0 }
        )
        $script:Session = [pscustomobject]@{ TargetNodeAddress = $script:Publisher.target_iqn }
        $script:Disk = [pscustomobject]@{ UniqueId = "0xaaa"; Number = 10; IsOffline = $false }
        Mock Ensure-PublisherPortal { }
        Mock Update-IscsiTarget { }
        Mock Connect-IscsiTarget { }
        Mock Get-PublisherSessionDisks { return @($script:Disk) }
        Mock Set-Disk { }
    }

    It "reuses an existing exact session without a duplicate login" {
        Mock Get-PublisherSession { return @($script:Session) }

        Connect-PublisherTarget `
            -Publisher $script:Publisher `
            -ExpectedVolumes $script:ExpectedVolumes

        Should -Invoke Connect-IscsiTarget -Times 0 -Exactly
        Should -Invoke Get-PublisherSessionDisks -Times 1 -Exactly
    }

    It "creates one non-persistent login when the target is disconnected" {
        $script:SessionChecks = 0
        Mock Get-PublisherSession {
            $script:SessionChecks++
            if ($script:SessionChecks -eq 1) { return @() }
            return @($script:Session)
        }

        Connect-PublisherTarget `
            -Publisher $script:Publisher `
            -ExpectedVolumes $script:ExpectedVolumes

        Should -Invoke Connect-IscsiTarget -Times 1 -Exactly -ParameterFilter {
            $IsPersistent -eq $false -and $NodeAddress -eq $script:Publisher.target_iqn
        }
        Should -Invoke Get-PublisherSessionDisks -Times 1 -Exactly
    }
}

Describe "Publisher stage and activation flow" {
    BeforeEach {
        $script:SimulationSourceIp = "192.168.1.101"
        $script:AllowHttpForSimulation = $true
        $script:Confirmation = "ACTIVATE games-2026.08.18.2"
        $script:ConfigPath = Join-Path $TestDrive "publisher.json"
        $script:TokenPath = Join-Path $TestDrive "admin.token"
        $script:PendingPath = Join-Path $TestDrive "publish.pending.json"
        Remove-Item -LiteralPath $script:PendingPath -Force -ErrorAction SilentlyContinue
        @{
            api_base_url = "http://admin"
            certificate_thumbprint = ""
        } | ConvertTo-Json | Set-Content -LiteralPath $script:ConfigPath
        Set-Content -LiteralPath $script:TokenPath -Value "redacted" -NoNewline
        $script:Publisher = [pscustomobject]@{
            target_iqn = "iqn.2026-08.lab.games:master"
            portal = [pscustomobject]@{ address = "10.20.40.10"; port = 3260 }
            volumes = @(
                [pscustomobject]@{ name = "ssd"; disk_unique_id = "aaa"; lun = 0 },
                [pscustomobject]@{ name = "hdd"; disk_unique_id = "bbb"; lun = 1 }
            )
        }
        $script:Session = [pscustomobject]@{ TargetNodeAddress = $script:Publisher.target_iqn }
        $script:Disks = @(
            [pscustomobject]@{ UniqueId = "0xaaa"; Number = 10; IsOffline = $false },
            [pscustomobject]@{ UniqueId = "0xbbb"; Number = 11; IsOffline = $false }
        )
        $script:Events = @()
        Mock Get-PublisherSession { return @($script:Session) }
        Mock Get-PublisherSessionDisks { return @($script:Disks) }
        Mock Set-PublisherDisksOffline { }
        Mock Disconnect-IscsiTarget { $script:Events += "disconnect" }
        Mock Connect-PublisherTarget { $script:Events += "reconnect" }
    }

    It "offlines, disconnects, stages, reconnects, and activates exact disks" {
        Mock Invoke-PublisherRequest {
            if ($Uri.EndsWith("/publisher")) { return $script:Publisher }
            if ($Uri.EndsWith("/stage")) {
                $script:Events += "stage"
                return [pscustomobject]@{ status = "staged"; release = "games-2026.08.18.2" }
            }
            $script:Events += "activate"
            return [pscustomobject]@{ status = "active"; release = "games-2026.08.18.2" }
        }

        $code = Invoke-PublisherMain `
            -PublisherConfigPath $script:ConfigPath `
            -AdminTokenPath $script:TokenPath `
            -StatePath $script:PendingPath

        $code | Should -Be 0
        Test-Path -LiteralPath $script:PendingPath | Should -BeFalse
        Should -Invoke Set-PublisherDisksOffline -Times 1 -Exactly
        Should -Invoke Disconnect-IscsiTarget -Times 1 -Exactly
        Should -Invoke Connect-PublisherTarget -Times 1 -Exactly
        Should -Invoke Invoke-PublisherRequest -Times 1 -Exactly -ParameterFilter {
            $Uri.EndsWith("/stage")
        }
        Should -Invoke Invoke-PublisherRequest -Times 1 -Exactly -ParameterFilter {
            $Uri.EndsWith("/activate")
        }
        ($script:Events -join ",") | Should -Be "disconnect,stage,reconnect,activate"
    }

    It "does not touch disks when NAA validation fails" {
        $script:Disks[1].UniqueId = "wrong"
        Mock Invoke-PublisherRequest { return $script:Publisher }

        $code = Invoke-PublisherMain `
            -PublisherConfigPath $script:ConfigPath `
            -AdminTokenPath $script:TokenPath `
            -StatePath $script:PendingPath

        $code | Should -Be 1
        Should -Invoke Set-PublisherDisksOffline -Times 0 -Exactly
        Should -Invoke Disconnect-IscsiTarget -Times 0 -Exactly
    }

    It "keeps the target disconnected when stage fails" {
        Mock Invoke-PublisherRequest {
            if ($Uri.EndsWith("/publisher")) { return $script:Publisher }
            throw "stage failed"
        }

        $code = Invoke-PublisherMain `
            -PublisherConfigPath $script:ConfigPath `
            -AdminTokenPath $script:TokenPath `
            -StatePath $script:PendingPath

        $code | Should -Be 1
        Test-Path -LiteralPath $script:PendingPath | Should -BeTrue
        Should -Invoke Disconnect-IscsiTarget -Times 1 -Exactly
        Should -Invoke Connect-PublisherTarget -Times 0 -Exactly
    }

    It "keeps a staged release pending when activation is declined" {
        $script:Confirmation = "no"
        Mock Invoke-PublisherRequest {
            if ($Uri.EndsWith("/publisher")) { return $script:Publisher }
            return [pscustomobject]@{ status = "staged"; release = "games-2026.08.18.2" }
        }

        $code = Invoke-PublisherMain `
            -PublisherConfigPath $script:ConfigPath `
            -AdminTokenPath $script:TokenPath `
            -StatePath $script:PendingPath

        $code | Should -Be 2
        Test-Path -LiteralPath $script:PendingPath | Should -BeTrue
        Should -Invoke Connect-PublisherTarget -Times 1 -Exactly
        Should -Invoke Invoke-PublisherRequest -Times 0 -Exactly -ParameterFilter {
            $Uri.EndsWith("/activate")
        }
        ($script:Events -join ",") | Should -Be "disconnect,reconnect"
    }

    It "resumes an interrupted stage without requiring the master session again" {
        Save-PendingPublication `
            -Path $script:PendingPath `
            -RequestId "same-stage-request"
        Mock Get-PublisherSession { throw "must not inspect a disconnected session" }
        Mock Invoke-PublisherRequest {
            if ($Uri.EndsWith("/publisher")) { return $script:Publisher }
            if ($Uri.EndsWith("/stage")) {
                $RequestId | Should -Be "same-stage-request"
                return [pscustomobject]@{ status = "staged"; release = "games-2026.08.18.2" }
            }
            return [pscustomobject]@{ status = "active"; release = "games-2026.08.18.2" }
        }

        $code = Invoke-PublisherMain `
            -PublisherConfigPath $script:ConfigPath `
            -AdminTokenPath $script:TokenPath `
            -StatePath $script:PendingPath

        $code | Should -Be 0
        Should -Invoke Get-PublisherSession -Times 0 -Exactly
        Should -Invoke Set-PublisherDisksOffline -Times 0 -Exactly
        Should -Invoke Disconnect-IscsiTarget -Times 0 -Exactly
        Should -Invoke Connect-PublisherTarget -Times 1 -Exactly
    }

    It "reconnects a previously staged pending release before activation" {
        Save-PendingPublication `
            -Path $script:PendingPath `
            -RequestId "same-stage-request" `
            -Release "games-2026.08.18.2"
        Mock Invoke-PublisherRequest {
            if ($Uri.EndsWith("/publisher")) { return $script:Publisher }
            if ($Uri.EndsWith("/stage")) { throw "stage must not run again" }
            $script:Events += "activate"
            return [pscustomobject]@{ status = "active"; release = "games-2026.08.18.2" }
        }

        $code = Invoke-PublisherMain `
            -PublisherConfigPath $script:ConfigPath `
            -AdminTokenPath $script:TokenPath `
            -StatePath $script:PendingPath

        $code | Should -Be 0
        Test-Path -LiteralPath $script:PendingPath | Should -BeFalse
        Should -Invoke Connect-PublisherTarget -Times 1 -Exactly
        Should -Invoke Invoke-PublisherRequest -Times 0 -Exactly -ParameterFilter {
            $Uri.EndsWith("/stage")
        }
        Should -Invoke Invoke-PublisherRequest -Times 1 -Exactly -ParameterFilter {
            $Uri.EndsWith("/activate")
        }
        ($script:Events -join ",") | Should -Be "reconnect,activate"
    }

    It "keeps a staged release pending and inactive when reconnect fails" {
        Mock Connect-PublisherTarget { throw "reconnect failed" }
        Mock Invoke-PublisherRequest {
            if ($Uri.EndsWith("/publisher")) { return $script:Publisher }
            if ($Uri.EndsWith("/stage")) {
                return [pscustomobject]@{ status = "staged"; release = "games-2026.08.18.2" }
            }
            return [pscustomobject]@{ status = "active"; release = "unexpected" }
        }

        $code = Invoke-PublisherMain `
            -PublisherConfigPath $script:ConfigPath `
            -AdminTokenPath $script:TokenPath `
            -StatePath $script:PendingPath

        $pending = Get-Content -LiteralPath $script:PendingPath -Raw | ConvertFrom-Json
        $code | Should -Be 1
        $pending.release | Should -Be "games-2026.08.18.2"
        Should -Invoke Connect-PublisherTarget -Times 1 -Exactly
        Should -Invoke Invoke-PublisherRequest -Times 0 -Exactly -ParameterFilter {
            $Uri.EndsWith("/activate")
        }
    }
}

Describe "Publisher stage retry" {
    It "reuses the request ID after a transient 503" {
        $script:attempt = 0
        Mock Start-Sleep { }
        Mock Invoke-PublisherRequest {
            $script:attempt++
            if ($script:attempt -eq 1) {
                $exception = New-Object System.Exception("injected")
                $exception.Data["StatusCode"] = 503
                throw $exception
            }
            return [pscustomobject]@{ status = "staged"; release = "games-2026.08.18.2" }
        }

        $result = Invoke-StageWithRetry `
            -BaseUrl "https://admin" `
            -Token "redacted" `
            -RequestId "same-request" `
            -TimeoutSeconds 5

        $result.status | Should -Be "staged"
        Should -Invoke Invoke-PublisherRequest -Times 2 -Exactly -ParameterFilter {
            $RequestId -eq "same-request"
        }
    }
}
