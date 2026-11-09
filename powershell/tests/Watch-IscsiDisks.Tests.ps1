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
        Write-WatchJson (Get-WatchPath "disk-watchdog-reset.json") @{ schema_version = 1; reset_id = "test-reset" }
        Set-WatchArm -VerifiedSnapshot ([pscustomobject]@{
            request_id = "reset-test"; reset_id = "test-reset"; target_iqn = "own-target"
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
            schema_version = 1; enabled = $true
        }
        Save-WatchState (Get-WatchState -BootId ([string]$boot))
    }

    It "waits for a successful reset snapshot and ignores foreign offline disks" {
        Invoke-WatchTick | Should -Be "waiting"
        Arm-TestWatch
        1..4 | ForEach-Object { Invoke-WatchTick | Should -Be "healthy" }
        (Get-TestWatchCommands "reboot_requested").Count | Should -Be 0
        (Get-TestWatchCommands "report_offline").Count | Should -Be 0
    }

    It "does not activate in the installation boot" {
        $state = Get-WatchState (Get-WatchBootId)
        $state.install_blocked = $true
        Save-WatchState $state
        Arm-TestWatch
        Fail-TestWatchDisk
        Confirm-TestWatchFailure
        (Get-WatchState (Get-WatchBootId)).arm | Should -BeNullOrEmpty
        (Get-TestWatchCommands "reboot_requested").Count | Should -Be 0
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
        $before = Get-WatchNowTicks
        Invoke-WatchTick | Should -Be "reboot_requested"
        (Get-WatchNowTicks) | Should -Be $before
        Invoke-WatchTick | Should -Be "reboot_requested"
        (Get-TestWatchCommands "report_offline").Count | Should -Be 1
        (Get-TestWatchCommands "reboot_requested").Count | Should -Be 1
        (Get-TestWatchCommands "reboot_requested")[0].details.delay_seconds | Should -Be 0
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
        (Get-TestWatchCommands "reboot_requested").Count | Should -Be 0
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

    It "stops on 2001 before reboot and cannot rearm after another reset" {
        Arm-TestWatch
        Fail-TestWatchDisk
        Invoke-WatchTick | Out-Null
        Invoke-WatchTick | Out-Null
        Set-WatchSessionStarted
        (Get-TestWatchCommands "watcher_stopped").Count | Should -Be 1
        Invoke-WatchTick | Should -Be "stopped"
        Reset-WatchObservation
        Arm-TestWatch
        Invoke-WatchTick | Should -Be "stopped"
        (Get-TestWatchCommands "reboot_requested").Count | Should -Be 0
        (Get-TestWatchCommands "report_offline").Count | Should -Be 0
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
        (Get-TestWatchCommands "reboot_requested").Count | Should -Be 0
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
        (Get-TestWatchCommands "reboot_requested").Count | Should -Be 0
    }

    It "checks <Protection> after preparing intent and immediately before shutdown" -TestCases @(
        @{ Protection = "fast_latch" }, @{ Protection = "event_history" }
    ) {
        param($Protection)
        Arm-TestWatch
        Fail-TestWatchDisk
        $script:FinalProtection = $Protection
        Mock Write-WatchLog {
            if ($script:FinalProtection -eq "fast_latch") {
                Write-WatchJson (Get-WatchPath "disk-watchdog-session.json") @{
                    schema_version = 1; observed_utc_ticks = [string](Get-WatchNowTicks)
                }
            } else {
                $windows = Read-WatchSimulation
                $windows.session_started = $true
                Save-TestWatchWindows $windows
            }
        } -ParameterFilter { $Event -eq "reboot_request_prepared" }
        Confirm-TestWatchFailure
        (Get-TestWatchCommands "reboot_requested").Count | Should -Be 0
        (Get-WatchState (Get-WatchBootId)).session_latched | Should -BeTrue
    }

    It "never attempts cancellation after an immediate reboot was accepted" {
        Arm-TestWatch
        Fail-TestWatchDisk
        Confirm-TestWatchFailure
        Mock Start-Process { throw "unexpected native command" }
        Set-WatchSessionStarted
        Invoke-WatchTick | Should -Be "stopped"
        Should -Invoke Start-Process -Times 0 -Exactly
        (Get-TestWatchCommands "reboot_requested").Count | Should -Be 1
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
        (Get-TestWatchCommands "reboot_requested").Count | Should -Be 1
        Get-Content (Get-WatchPath "logs/disk-watchdog.jsonl") -Raw | Should -Not -Match 'secret-token|HTTP headers'
    }

    It "fails without cancellation if the immediate reboot command fails" {
        Arm-TestWatch
        Fail-TestWatchDisk
        Mock Invoke-WatchShutdown { throw "another reboot is already pending" }
        Mock Start-Process { throw "unexpected cancellation" }
        Invoke-WatchTick | Out-Null
        Invoke-WatchTick | Out-Null
        { Invoke-WatchTick } | Should -Throw "*Reboot request failed*"
        Should -Invoke Invoke-WatchShutdown -Times 1 -Exactly
        Should -Invoke Start-Process -Times 0 -Exactly
        (Get-WatchState (Get-WatchBootId)).reboot_requested | Should -BeFalse
    }

    It "does not issue shutdown before intent is durable and can retry without another POST" {
        Arm-TestWatch
        Fail-TestWatchDisk
        $script:RealSaveWatchState = ${function:Save-WatchState}
        $script:FailIntentSave = $true
        Mock Save-WatchState {
            if ($State.reboot_requested -and $script:FailIntentSave) {
                $script:FailIntentSave = $false
                throw "simulated failure before native command"
            }
            & $script:RealSaveWatchState $State
        }
        Invoke-WatchTick | Out-Null
        Invoke-WatchTick | Out-Null
        { Invoke-WatchTick } | Should -Throw "*before native command*"
        (Get-TestWatchCommands "reboot_requested").Count | Should -Be 0
        Invoke-WatchTick | Should -Be "reboot_requested"
        Invoke-WatchMain # A restarted worker must not duplicate accepted intent.
        (Get-TestWatchCommands "reboot_requested").Count | Should -Be 1
        (Get-TestWatchCommands "report_offline").Count | Should -Be 1
    }

    It "allows six reboots within an hour with <Runtime> runtime files" -TestCases @(
        @{ Runtime = "missing" }, @{ Runtime = "shadow-restored" }
    ) {
        param($Runtime)
        Arm-TestWatch
        $oldArm = (Get-WatchState (Get-WatchBootId)).arm
        Set-WatchSessionStarted
        $baseline = Read-WatchJson (Get-WatchPath "disk-watchdog-state.json")
        $baseline.arm = $oldArm
        $baseline.install_blocked = $true
        $oldLatch = Read-WatchJson (Get-WatchPath "disk-watchdog-session.json")
        foreach ($number in 1..6) {
            $windows = Read-WatchSimulation
            $windows.boot_id = [string]([long]$windows.now_utc_ticks + [TimeSpan]::FromMinutes(1).Ticks)
            $windows.now_utc_ticks = [string]([long]$windows.boot_id + [TimeSpan]::FromMinutes(1).Ticks)
            $windows.disks[0].is_offline = $false
            Save-TestWatchWindows $windows
            foreach ($file in @("disk-watchdog-state.json", "disk-watchdog-session.json", "disk-watchdog-reset.json")) {
                Remove-Item (Get-WatchPath $file) -ErrorAction SilentlyContinue
            }
            if ($Runtime -eq "shadow-restored") {
                Write-WatchJson (Get-WatchPath "disk-watchdog-state.json") $baseline
                Write-WatchJson (Get-WatchPath "disk-watchdog-session.json") $oldLatch
                Write-WatchJson (Get-WatchPath "disk-watchdog-reset.json") @{ schema_version = 1; reset_id = "old-reset" }
            }
            Invoke-WatchTick | Should -Be "waiting"
            (Get-TestWatchCommands "reboot_requested").Count | Should -Be ($number - 1)
            Arm-TestWatch
            Fail-TestWatchDisk
            Confirm-TestWatchFailure
            Invoke-WatchMain
            (Get-TestWatchCommands "reboot_requested").Count | Should -Be $number
            (Get-TestWatchCommands "report_offline").Count | Should -Be $number
        }
    }

    It "invalidates the old arm before intentional reset mutations" {
        Arm-TestWatch
        Fail-TestWatchDisk
        Invoke-WatchTick | Out-Null
        Invoke-WatchTick | Out-Null
        Write-WatchJson (Get-WatchPath "disk-watchdog-reset.json") @{ schema_version = 1; reset_id = "new-reset" }
        Invoke-WatchTick | Should -Be "waiting"
        (Get-TestWatchCommands "reboot_requested").Count | Should -Be 0
    }

    It "waits rather than exiting if Reset starts during the report" {
        Arm-TestWatch
        Fail-TestWatchDisk
        Mock Invoke-WatchOfflinePost { Reset-WatchObservation }
        Invoke-WatchTick | Out-Null
        Invoke-WatchTick | Out-Null
        Invoke-WatchTick | Should -Be "waiting"
        (Get-TestWatchCommands "reboot_requested").Count | Should -Be 0
        $windows = Read-WatchSimulation
        $windows.disks[0].is_offline = $false
        Save-TestWatchWindows $windows
        Arm-TestWatch
        Invoke-WatchTick | Should -Be "healthy"
    }

    It "ignores previous-boot arms and latches" {
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
        (Get-TestWatchCommands "reboot_requested").Count | Should -Be 0
    }

    It "does not reboot if <File> becomes unreadable during the POST" -TestCases @(
        @{ File = "disk-watchdog-state.json" }, @{ File = "disk-watchdog-session.json" },
        @{ File = "disk-watchdog.json" }
    ) {
        param($File)
        Arm-TestWatch
        Fail-TestWatchDisk
        $script:BreakWatchFile = $File
        Mock Invoke-WatchOfflinePost {
            Set-Content -LiteralPath (Get-WatchPath $script:BreakWatchFile) -Value 'broken-json'
        }
        Invoke-WatchMain
        (Get-TestWatchCommands "reboot_requested").Count | Should -Be 0
    }

    It "stops the task even if session handling cannot read the current state" {
        Arm-TestWatch
        Set-Content -LiteralPath (Get-WatchPath "disk-watchdog-state.json") -Value 'broken-json'
        { Set-WatchSessionStarted } | Should -Throw
        (Get-TestWatchCommands "watcher_stopped").Count | Should -Be 1
        Invoke-WatchMain
        (Get-TestWatchCommands "reboot_requested").Count | Should -Be 0
    }

    It "ignores old v1 state before validating removed history or ownership" {
        $oldBoot = [string]([long](Get-WatchBootId) - [TimeSpan]::FromMinutes(1).Ticks)
        Write-WatchJson (Get-WatchPath "disk-watchdog-state.json") @{
            schema_version = 1; boot_id = $oldBoot; session_latched = $true
            arm = "stale-arm"; recent_reboots = @(@{ ticks = "future-or-invalid" })
            pending = @{ phase = "scheduled"; boot_id = $oldBoot; deadline_ticks = "irrelevant" }
        }
        Invoke-WatchTick | Should -Be "waiting"
        Arm-TestWatch
        Invoke-WatchTick | Should -Be "healthy"
        (Get-WatchState (Get-WatchBootId)).schema_version | Should -Be 2
        (Get-TestWatchCommands "reboot_requested").Count | Should -Be 0
    }

    It "migrates current-boot v1 protection but discards legacy reboot history" {
        $legacy = @{
            schema_version = 1; boot_id = (Get-WatchBootId); session_latched = $true
            last_event_record = 100; recent_reboots = @("irrelevant-history"); pending = $null
        }
        Write-WatchJson (Get-WatchPath "disk-watchdog-state.json") $legacy
        Arm-TestWatch
        Invoke-WatchTick | Should -Be "stopped"
        $state = Get-WatchState (Get-WatchBootId)
        $state.schema_version | Should -Be 2
        $state.PSObject.Properties.Name | Should -Not -Contain "recent_reboots"
        $state.PSObject.Properties.Name | Should -Not -Contain "pending"
    }

    It "recreates missing state disarmed and retains <Protection> protection" -TestCases @(
        @{ Protection = "fast_latch" }, @{ Protection = "event_history" }, @{ Protection = "none" }
    ) {
        param($Protection)
        Arm-TestWatch
        if ($Protection -eq "fast_latch") { Set-WatchSessionStarted }
        if ($Protection -eq "event_history") {
            $windows = Read-WatchSimulation
            $windows.session_started = $true
            Save-TestWatchWindows $windows
        }
        Remove-Item (Get-WatchPath "disk-watchdog-state.json")
        $expected = if ($Protection -eq "none") { "waiting" } else { "stopped" }
        Invoke-WatchTick | Should -Be $expected
        (Get-WatchState (Get-WatchBootId)).arm | Should -BeNullOrEmpty
        Reset-WatchObservation
        Arm-TestWatch
        $expected = if ($Protection -eq "none") { "healthy" } else { "stopped" }
        Invoke-WatchTick | Should -Be $expected
        (Get-TestWatchCommands "reboot_requested").Count | Should -Be 0
    }

    It "does not reboot if event history becomes unreadable or is cleared" -TestCases @(
        @{ Cleared = $false }, @{ Cleared = $true }
    ) {
        param($Cleared)
        Arm-TestWatch
        Fail-TestWatchDisk
        Invoke-WatchTick | Out-Null
        Invoke-WatchTick | Out-Null
        $windows = Read-WatchSimulation
        if ($Cleared) { $windows.event_record_id = 1 } else { $windows.event_error = $true }
        Save-TestWatchWindows $windows
        Invoke-WatchMain
        (Get-TestWatchCommands "reboot_requested").Count | Should -Be 0
    }

    It "uses the same mutex for equivalent install paths" {
        $name = Get-WatchMutexName
        $script:WatchRoot += [IO.Path]::DirectorySeparatorChar
        Get-WatchMutexName | Should -Be $name
    }

    It "refuses a duplicate worker" {
        $fake = [pscustomobject]@{ Disposed = $false }
        $fake | Add-Member ScriptMethod WaitOne { param($timeout) return $false }
        $fake | Add-Member ScriptMethod Dispose { $this.Disposed = $true }
        $script:WatchFakeMutex = $fake
        Mock New-WatchMutex { return $script:WatchFakeMutex } -ParameterFilter { $Suffix -eq "Worker" }
        Invoke-WatchMain
        $fake.Disposed | Should -BeTrue
        (Get-TestWatchCommands "reboot_requested").Count | Should -Be 0
    }

    It "requests the exact immediate native shutdown command" {
        $script:WatchSimulationPath = ""
        if (-not $env:SystemRoot) { $env:SystemRoot = "/windows" }
        $process = [pscustomobject]@{ ExitCode = 0 }
        $process | Add-Member ScriptMethod WaitForExit { param($timeout) return $true }
        $process | Add-Member ScriptMethod Dispose { }
        $script:NativeShutdownProcess = $process
        Mock Start-Process { return $script:NativeShutdownProcess }
        Invoke-WatchShutdown -Id "test-id"
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
            $FilePath -like "*shutdown.exe" -and
            $ArgumentList -eq '/r /f /t 0 /d p:4:1 /c "iSCSI disk watcher test-id"'
        }
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
