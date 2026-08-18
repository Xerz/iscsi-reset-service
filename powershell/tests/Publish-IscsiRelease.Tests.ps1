BeforeAll {
    $script:PublisherScriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) "Publish-IscsiRelease.ps1"
    . $script:PublisherScriptPath -NoMain
    if ($null -eq (Get-Command Disconnect-IscsiTarget -ErrorAction SilentlyContinue)) {
        function Disconnect-IscsiTarget { }
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

Describe "Publisher stage and activation flow" {
    BeforeEach {
        $script:SimulationSourceIp = "192.168.1.101"
        $script:AllowHttpForSimulation = $true
        $script:Confirmation = "ACTIVATE games-2026.08.18.2"
        $script:ConfigPath = Join-Path $TestDrive "publisher.json"
        $script:TokenPath = Join-Path $TestDrive "admin.token"
        $script:PendingPath = Join-Path $TestDrive "publish.pending.json"
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
        Mock Get-PublisherSession { return @($script:Session) }
        Mock Get-PublisherSessionDisks { return @($script:Disks) }
        Mock Set-PublisherDisksOffline { }
        Mock Disconnect-IscsiTarget { }
        Mock Connect-PublisherTarget { }
    }

    It "offlines, disconnects, stages, activates, and reconnects exact disks" {
        Mock Invoke-PublisherRequest {
            if ($Uri.EndsWith("/publisher")) { return $script:Publisher }
            if ($Uri.EndsWith("/stage")) {
                return [pscustomobject]@{ status = "staged"; release = "games-2026.08.18.2" }
            }
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
