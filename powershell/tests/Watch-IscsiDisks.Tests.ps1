BeforeAll {
    . (Join-Path (Split-Path $PSScriptRoot -Parent) "Watch-IscsiDisks.ps1") -NoMain
    if (-not (Get-Command Get-WinEvent -ErrorAction SilentlyContinue)) {
        function Get-WinEvent { param($LogName, $MaxEvents, $FilterHashtable, $ErrorAction) }
    }
    function Save-TestWatchWindows { param($Value) Write-WatchJson $script:WatchSimulationPath $Value }
    function Get-TestWatchCommands {
        param([string]$Name)
        return ,@((Read-WatchSimulation).commands | Where-Object name -eq $Name)
    }
    function Arm-TestWatch {
        Set-WatchArm -VerifiedSnapshot ([pscustomobject]@{
            request_id = "reset-test"; reset_id = ""; target_iqn = "own-target"
            session_identifier = "own-session"; disk_unique_ids = @("0xAAA", " bbb ", "ccc")
        })
    }
    function Fail-TestWatchDisk {
        $windows = Read-WatchSimulation
        $windows.disks[0].is_offline = $true
        $windows.disks[0].offline_reason = 5
        Save-TestWatchWindows $windows
    }
    function Confirm-TestWatchFailure {
        1..3 | ForEach-Object { $null = Invoke-WatchTick; Wait-WatchSeconds 5 }
    }
}

Describe "iSCSI disk watcher safety state machine" {
    BeforeEach {
        $script:WatchRoot = Join-Path $TestDrive "watcher"
        if (Test-Path $script:WatchRoot) { Remove-Item $script:WatchRoot -Recurse -Force }
        New-Item -ItemType Directory -Path (Join-Path $script:WatchRoot "logs") -Force | Out-Null
        $script:WatchSimulationPath = Join-Path $TestDrive "windows-watch.json"
        $boot = [DateTime]::Parse("2026-11-09T00:00:00Z").ToUniversalTime().Ticks
        Save-TestWatchWindows ([pscustomobject]@{
            boot_id = [string]$boot; now_utc_ticks = [string]($boot + [TimeSpan]::FromMinutes(10).Ticks)
            session_started = $false; event_error = $false; event_record_id = 100; storage_error = $false
            sessions = @([pscustomobject]@{ target_iqn = "own-target"; session_identifier = "own-session" })
            disks = @(
                [pscustomobject]@{ target_iqn = "own-target"; unique_id = "0xaaa"; is_offline = $false; offline_reason = 0 },
                [pscustomobject]@{ target_iqn = "own-target"; unique_id = "bbb"; is_offline = $false; offline_reason = 0 },
                [pscustomobject]@{ target_iqn = "own-target"; unique_id = "ccc"; is_offline = $false; offline_reason = 0 },
                [pscustomobject]@{ target_iqn = "foreign-target"; unique_id = "foreign-system-disk"; is_offline = $true; offline_reason = 5 }
            )
            commands = @(); report_status_codes = @(200)
        })
        Write-WatchJson (Get-WatchPath "disk-watchdog.json") @{
            schema_version = 1; enabled = $true; installed_boot_id = [string]($boot - 1)
        }
        Save-WatchState (Get-WatchState -BootId ([string]$boot) -Initialize)
    }

    It "waits for a successful reset snapshot and ignores foreign offline disks" {
        Invoke-WatchTick | Should -Be "waiting"
        Arm-TestWatch
        1..4 | ForEach-Object { Invoke-WatchTick | Should -Be "healthy" }
        (Get-TestWatchCommands "reboot_scheduled").Count | Should -Be 0
        (Get-TestWatchCommands "report_offline").Count | Should -Be 0
    }

    It "does not activate in the installation boot" {
        $config = Get-WatchConfig
        $config.installed_boot_id = Get-WatchBootId
        Write-WatchJson (Get-WatchPath "disk-watchdog.json") $config
        Arm-TestWatch
        Fail-TestWatchDisk
        Confirm-TestWatchFailure
        (Get-WatchState (Get-WatchBootId)).arm | Should -BeNullOrEmpty
        (Get-TestWatchCommands "reboot_scheduled").Count | Should -Be 0
    }

    It "requires three observations for <Fault> and sends one incident report" -TestCases @(
        @{ Fault = "offline" }, @{ Fault = "disk_missing" }, @{ Fault = "session_missing" }
    ) {
        param($Fault)
        Arm-TestWatch
        $windows = Read-WatchSimulation
        switch ($Fault) {
            "offline" { $windows.disks[2].is_offline = $true; $windows.disks[2].offline_reason = 5 }
            "disk_missing" { $windows.disks = @($windows.disks | Where-Object unique_id -ne "ccc") }
            "session_missing" { $windows.sessions = @() }
        }
        Save-TestWatchWindows $windows
        Invoke-WatchTick | Should -Be "suspect"
        Wait-WatchSeconds 5
        Invoke-WatchTick | Should -Be "suspect"
        (Get-TestWatchCommands "report_offline").Count | Should -Be 0
        Wait-WatchSeconds 5
        Invoke-WatchTick | Should -Be "notify"
        Invoke-WatchTick | Should -Be "pending"
        (Get-TestWatchCommands "report_offline").Count | Should -Be 1
        (Get-TestWatchCommands "reboot_scheduled").Count | Should -Be 1
        (Get-TestWatchCommands "reboot_scheduled")[0].details.delay_seconds | Should -Be 30
    }

    It "resets the failure counter after recovery or a storage query error" {
        Arm-TestWatch
        Fail-TestWatchDisk
        Invoke-WatchTick | Should -Be "suspect"
        Invoke-WatchTick | Should -Be "suspect"
        $windows = Read-WatchSimulation
        $windows.storage_error = $true
        Save-TestWatchWindows $windows
        Invoke-WatchTick | Should -Be "unknown"
        $windows.storage_error = $false
        Save-TestWatchWindows $windows
        Invoke-WatchTick | Should -Be "suspect"
        $windows.disks[0].is_offline = $false
        Save-TestWatchWindows $windows
        Invoke-WatchTick | Should -Be "healthy"
        Fail-TestWatchDisk
        Invoke-WatchTick | Should -Be "suspect"
        (Get-TestWatchCommands "reboot_scheduled").Count | Should -Be 0
    }

    It "treats ambiguous NAA as an observation error" {
        Arm-TestWatch
        $windows = Read-WatchSimulation
        $windows.disks[2].unique_id = "aaa"
        Save-TestWatchWindows $windows
        1..4 | ForEach-Object { Invoke-WatchTick | Should -Be "unknown" }
        (Get-TestWatchCommands "report_offline").Count | Should -Be 0
    }

    It "honors 2001 recorded before arming and never rearms in that boot" {
        $windows = Read-WatchSimulation
        $windows.session_started = $true
        Save-TestWatchWindows $windows
        Arm-TestWatch
        Invoke-WatchTick | Should -Be "stopped"
        $windows.session_started = $false
        Save-TestWatchWindows $windows
        Arm-TestWatch
        Invoke-WatchTick | Should -Be "stopped"
        (Get-WatchState (Get-WatchBootId)).arm | Should -BeNullOrEmpty
    }

    It "cancels its queued reboot on 2001 and stops its task" {
        Arm-TestWatch
        Fail-TestWatchDisk
        Confirm-TestWatchFailure
        Set-WatchSessionStarted
        (Get-TestWatchCommands "reboot_aborted").Count | Should -Be 1
        (Get-TestWatchCommands "watcher_stopped").Count | Should -Be 1
        Invoke-WatchTick | Should -Be "stopped"
        Arm-TestWatch
        Invoke-WatchTick | Should -Be "stopped"
        (Get-TestWatchCommands "reboot_scheduled").Count | Should -Be 1
    }

    It "never aborts a reboot without an owned accepted pending record" {
        Arm-TestWatch
        Set-WatchSessionStarted
        (Get-TestWatchCommands "reboot_aborted").Count | Should -Be 0
    }

    It "gives 2001 priority while report-offline is in flight" {
        Arm-TestWatch
        Fail-TestWatchDisk
        Mock Invoke-WatchOfflinePost {
            Add-WatchSimulationCommand "report_offline"
            Set-WatchSessionStarted
        }
        Confirm-TestWatchFailure
        (Get-TestWatchCommands "report_offline").Count | Should -Be 1
        (Get-TestWatchCommands "reboot_scheduled").Count | Should -Be 0
    }

    It "checks 2001 again after reporting and before scheduling" {
        Arm-TestWatch
        Fail-TestWatchDisk
        Mock Send-WatchOfflineBatch {
            $windows = Read-WatchSimulation
            $windows.session_started = $true
            Save-TestWatchWindows $windows
            return $true
        }
        Confirm-TestWatchFailure
        (Get-TestWatchCommands "reboot_scheduled").Count | Should -Be 0
    }

    It "cancels if the fast latch is written during shutdown acceptance" {
        Arm-TestWatch
        Fail-TestWatchDisk
        Mock Invoke-WatchShutdown {
            if ($Cancel) { Add-WatchSimulationCommand "reboot_aborted" }
            else {
                Add-WatchSimulationCommand "reboot_scheduled"
                Write-WatchJson (Get-WatchPath "disk-watchdog-session.json") @{
                    schema_version = 1; observed_utc_ticks = [string](Get-WatchNowTicks)
                }
            }
        }
        Confirm-TestWatchFailure
        (Get-TestWatchCommands "reboot_aborted").Count | Should -Be 1
        (Get-WatchState (Get-WatchBootId)).session_latched | Should -BeTrue
    }

    It "reboots after three failed reports without logging sensitive failures" {
        Arm-TestWatch
        Fail-TestWatchDisk
        Mock Invoke-WatchOfflinePost {
            Add-WatchSimulationCommand "report_offline"
            throw "secret-token HTTP headers and response must not appear in a log"
        }
        Confirm-TestWatchFailure
        Should -Invoke Invoke-WatchOfflinePost -Times 3 -Exactly
        (Get-TestWatchCommands "reboot_scheduled").Count | Should -Be 1
        Get-Content (Get-WatchPath "logs/disk-watchdog.jsonl") -Raw | Should -Not -Match 'secret-token|HTTP headers'
    }

    It "does not cancel someone else's shutdown when its scheduling command fails" {
        Arm-TestWatch
        Fail-TestWatchDisk
        Mock Invoke-WatchShutdown { throw "another reboot is already pending" }
        Invoke-WatchTick | Out-Null
        Invoke-WatchTick | Out-Null
        { Invoke-WatchTick } | Should -Throw "*scheduling failed*"
        Should -Invoke Invoke-WatchShutdown -Times 0 -Exactly -ParameterFilter { $Cancel }
        @((Get-WatchState (Get-WatchBootId)).recent_reboots).Count | Should -Be 0
    }

    It "cancels acceptance if persisting the scheduled phase fails and can reconcile" {
        Arm-TestWatch
        Fail-TestWatchDisk
        $script:RealSaveWatchState = ${function:Save-WatchState}
        $script:FailScheduledSave = $true
        Mock Save-WatchState {
            if ($null -ne $State.pending -and $State.pending.phase -eq "scheduled" -and $script:FailScheduledSave) {
                $script:FailScheduledSave = $false
                throw "simulated failure immediately after native acceptance"
            }
            & $script:RealSaveWatchState $State
        }
        Invoke-WatchTick | Out-Null
        Invoke-WatchTick | Out-Null
        { Invoke-WatchTick } | Should -Throw "*scheduling failed*"
        (Get-TestWatchCommands "reboot_scheduled").Count | Should -Be 1
        (Get-TestWatchCommands "reboot_aborted").Count | Should -Be 1
        (Get-WatchState (Get-WatchBootId)).pending | Should -BeNullOrEmpty
        Invoke-WatchTick | Should -Be "reboot"
        (Get-TestWatchCommands "reboot_scheduled").Count | Should -Be 2
        (Get-TestWatchCommands "report_offline").Count | Should -Be 1
    }

    It "persists the hourly limit across boots, reports once, and retries when it expires" {
        $state = Get-WatchState (Get-WatchBootId)
        $now = Get-WatchNowTicks
        $state.recent_reboots = @(10, 20, 30 | ForEach-Object {
            [pscustomobject]@{ id = "old-$_"; ticks = [string]($now - [TimeSpan]::FromMinutes($_).Ticks) }
        })
        Save-WatchState $state
        $windows = Read-WatchSimulation
        $windows.boot_id = [string]([long]$windows.boot_id + [TimeSpan]::FromMinutes(1).Ticks)
        Save-TestWatchWindows $windows
        Arm-TestWatch
        Fail-TestWatchDisk
        Confirm-TestWatchFailure
        1..5 | ForEach-Object { Invoke-WatchTick | Should -Be "rate_limited" }
        (Get-TestWatchCommands "report_offline").Count | Should -Be 1
        (Get-TestWatchCommands "reboot_scheduled").Count | Should -Be 0
        Wait-WatchSeconds 1900
        Invoke-WatchTick | Should -Be "reboot"
        (Get-TestWatchCommands "report_offline").Count | Should -Be 1
        (Get-TestWatchCommands "reboot_scheduled").Count | Should -Be 1
        @((Get-WatchState (Get-WatchBootId)).recent_reboots).Count | Should -Be 3
    }

    It "invalidates the old arm before intentional reset mutations" {
        Arm-TestWatch
        Fail-TestWatchDisk
        Confirm-TestWatchFailure
        Write-WatchJson (Get-WatchPath "disk-watchdog-reset.json") @{ schema_version = 1; reset_id = "new-reset" }
        Invoke-WatchTick | Should -Be "waiting"
        (Get-TestWatchCommands "reboot_aborted").Count | Should -Be 1
    }

    It "waits rather than exiting if Reset starts during the report" {
        Arm-TestWatch
        Fail-TestWatchDisk
        Mock Invoke-WatchOfflinePost { Reset-WatchObservation }
        Invoke-WatchTick | Out-Null
        Invoke-WatchTick | Out-Null
        Invoke-WatchTick | Should -Be "waiting"
        (Get-TestWatchCommands "reboot_scheduled").Count | Should -Be 0
        $windows = Read-WatchSimulation
        $windows.disks[0].is_offline = $false
        Save-TestWatchWindows $windows
        Arm-TestWatch
        Invoke-WatchTick | Should -Be "healthy"
    }

    It "ignores previous-boot arms and latches while keeping reboot history" {
        Arm-TestWatch
        Set-WatchSessionStarted
        $windows = Read-WatchSimulation
        $windows.boot_id = [string]([long]$windows.now_utc_ticks + [TimeSpan]::FromMinutes(1).Ticks)
        $windows.now_utc_ticks = [string]([long]$windows.boot_id + [TimeSpan]::FromMinutes(1).Ticks)
        Save-TestWatchWindows $windows
        Invoke-WatchTick | Should -Be "waiting"
        Arm-TestWatch
        Invoke-WatchTick | Should -Be "healthy"
    }

    It "does not reboot with corrupt <File> protection state" -TestCases @(
        @{ File = "disk-watchdog-state.json" }, @{ File = "disk-watchdog-session.json" },
        @{ File = "disk-watchdog.json" }
    ) {
        param($File)
        Arm-TestWatch
        Set-Content -LiteralPath (Get-WatchPath $File) -Value 'broken-json'
        { Invoke-WatchTick } | Should -Throw
        (Get-TestWatchCommands "reboot_scheduled").Count | Should -Be 0
    }

    It "does not reset the budget when state disappears" {
        Arm-TestWatch
        Remove-Item (Get-WatchPath "disk-watchdog-state.json")
        { Invoke-WatchTick } | Should -Throw "*state missing*"
    }

    It "cancels a queued reboot if event history becomes unreadable or is cleared" -TestCases @(
        @{ Cleared = $false }, @{ Cleared = $true }
    ) {
        param($Cleared)
        Arm-TestWatch
        Fail-TestWatchDisk
        Confirm-TestWatchFailure
        $windows = Read-WatchSimulation
        if ($Cleared) { $windows.event_record_id = 1 } else { $windows.event_error = $true }
        Save-TestWatchWindows $windows
        Invoke-WatchMain
        (Get-TestWatchCommands "reboot_aborted").Count | Should -Be 1
    }

    It "refuses a duplicate worker" {
        $fake = [pscustomobject]@{ Disposed = $false }
        $fake | Add-Member ScriptMethod WaitOne { param($timeout) return $false }
        $fake | Add-Member ScriptMethod Dispose { $this.Disposed = $true }
        $script:WatchFakeMutex = $fake
        Mock New-WatchMutex { return $script:WatchFakeMutex } -ParameterFilter { $Suffix -eq "Worker" }
        Invoke-WatchMain
        $fake.Disposed | Should -BeTrue
        (Get-TestWatchCommands "reboot_scheduled").Count | Should -Be 0
    }

    It "uses the exact Drova request contract and discards the response body" {
        $script:WatchSimulationPath = ""
        Mock Get-WatchDrovaCredentials {
            return [pscustomobject]@{ ServerId = "10000000-0000-0000-0000-000000000001"; Token = "sensitive-test-token" }
        }
        Mock Invoke-RestMethod { return "sensitive-response" }
        @(Invoke-WatchOfflinePost).Count | Should -Be 0
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $Method -eq "Post" -and
            $Uri -eq "https://services.drova.io/server-manager/servers/10000000-0000-0000-0000-000000000001/report-offline" -and
            $Headers["X-Auth-Token"] -eq "sensitive-test-token" -and $Body -eq '{}' -and
            $ContentType -eq "application/json" -and $TimeoutSec -eq 10 -and $MaximumRedirection -eq 0
        }
    }

    It "filters native disk observations by both target and session identity" {
        Arm-TestWatch
        $arm = (Get-WatchState (Get-WatchBootId)).arm
        $script:NativeWatchBoot = Get-WatchBootId
        $script:WatchSimulationPath = ""
        Mock Get-WatchBootId { return $script:NativeWatchBoot }
        Mock Get-WatchNativeSessions {
            return @(
                [pscustomobject]@{ TargetNodeAddress = "own-target"; SessionIdentifier = "own-session" },
                [pscustomobject]@{ TargetNodeAddress = "other-target"; SessionIdentifier = "foreign-session" }
            )
        }
        Mock Get-WatchNativeDisks {
            $Session.SessionIdentifier | Should -Be "own-session"
            return @(
                [pscustomobject]@{ UniqueId = "0xAAA"; IsOffline = $false; OfflineReason = 0 },
                [pscustomobject]@{ UniqueId = "bbb"; IsOffline = $false; OfflineReason = 0 },
                [pscustomobject]@{ UniqueId = "ccc"; IsOffline = $true; OfflineReason = 5 }
            )
        }
        $health = Get-WatchDiskHealth $arm
        $health.Healthy | Should -BeFalse
        @($health.Faults).Count | Should -Be 1
        $health.Faults[0].disk_unique_id | Should -Be "ccc"
        $health.Faults[0].offline_reason | Should -Be 5
    }

    It "reads native Application/esme/2001 history since this boot" {
        $bootId = Get-WatchBootId
        $script:WatchSimulationPath = ""
        Mock Get-WinEvent {
            if ($null -ne $FilterHashtable) { return [pscustomobject]@{ Id = 2001 } }
            return [pscustomobject]@{ RecordId = 500 }
        }
        $events = Get-WatchEventState $bootId
        $events.SeenSession | Should -BeTrue
        $events.RecordId | Should -Be 500
        Should -Invoke Get-WinEvent -Times 1 -Exactly -ParameterFilter {
            $FilterHashtable.LogName -eq "Application" -and $FilterHashtable.ProviderName -eq "esme" -and
            $FilterHashtable.Id -eq 2001 -and $FilterHashtable.StartTime.ToUniversalTime().Ticks -eq [long]$bootId
        }
    }
}
