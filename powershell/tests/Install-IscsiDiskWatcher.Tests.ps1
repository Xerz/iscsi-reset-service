BeforeAll {
    . (Join-Path (Split-Path $PSScriptRoot -Parent) "Watch-IscsiDisks.ps1") -NoMain
    $script:WatcherInstaller = Join-Path (Split-Path $PSScriptRoot -Parent) "Install-IscsiDiskWatcher.ps1"
    . $script:WatcherInstaller -NoMain
    foreach ($name in @("Get-ScheduledTask", "Stop-ScheduledTask", "Unregister-ScheduledTask")) {
        if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
            Set-Item "function:$name" { param($TaskPath, $TaskName, $Confirm, $ErrorAction) }
        }
    }
    if (-not (Get-Command Register-ScheduledTask -ErrorAction SilentlyContinue)) {
        function Register-ScheduledTask { param($TaskPath, $TaskName, $Xml, $Force, $ErrorAction) }
    }
    if (-not (Get-Command Get-CimInstance -ErrorAction SilentlyContinue)) {
        function Get-CimInstance { param($ClassName, $OperationTimeoutSec, $ErrorAction) }
    }
}

Describe "Disk watcher installer ownership and preservation" {
    BeforeEach {
        $InstallRoot = Join-Path $TestDrive "installed"
        if (Test-Path $InstallRoot) { Remove-Item $InstallRoot -Recurse -Force }
        New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
        Set-Content (Join-Path $InstallRoot "Reset-And-Connect.ps1") "original-reset"
        foreach ($file in @("client.token", "reset-ca.crt", "egs-sync.json", "majestic-sync.json", "gta5rp-sync.json")) {
            Set-Content (Join-Path $InstallRoot $file) "preserve-$file"
        }
        $ClientScriptPath = Join-Path $TestDrive "new-reset.ps1"
        Set-Content $ClientScriptPath 'function Invoke-ResetDiskWatcherHook { }'
        $WatcherScriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) "Watch-IscsiDisks.ps1"
        $Uninstall = $false
        if (-not $env:SystemRoot) { $env:SystemRoot = "/windows" }
        $script:InstallerOwnedTasks = @()
        $script:RootResetRunning = $false
        $script:FailRegisterWatcher = $false
        $script:InstallerBootDate = [DateTime]::UtcNow.AddHours(-1)
        Mock Assert-WatcherAdministrator { }
        Mock Set-WatcherRestrictedAcl { }
        Mock Ensure-WatcherTaskFolder { }
        Mock Get-CimInstance {
            return [pscustomobject]@{ LastBootUpTime = $script:InstallerBootDate }
        }
        Mock Get-ScheduledTask {
            if ($TaskPath -eq "\" -and $TaskName -eq "iSCSI Reset and Connect") {
                if ($script:RootResetRunning) { return [pscustomobject]@{ State = "Running" } }
                return $null
            }
            return @($script:InstallerOwnedTasks | Where-Object TaskName -eq $TaskName) | Select-Object -First 1
        }
        Mock Stop-ScheduledTask { }
        Mock Unregister-ScheduledTask { }
        Mock Register-ScheduledTask {
            if ($script:FailRegisterWatcher) { throw "registration failed" }
            $script:InstallerOwnedTasks = @($script:InstallerOwnedTasks | Where-Object TaskName -ne $TaskName)
            $script:InstallerOwnedTasks += [pscustomobject]@{
                TaskPath = $TaskPath; TaskName = $TaskName; State = "Ready"
                Description = $script:DiskWatcherOwner
            }
        }
    }

    It "generates SYSTEM XML with boot and exact esme/2001 triggers" {
        $watch = [xml](New-WatcherTaskXml -Root $InstallRoot -Action Watch)
        $stop = [xml](New-WatcherTaskXml -Root $InstallRoot -Action SessionStarted)
        $watch.Task.Principals.Principal.UserId | Should -Be "S-1-5-18"
        $watch.Task.Principals.Principal.RunLevel | Should -Be "HighestAvailable"
        $watch.GetElementsByTagName("LogonType").Count | Should -Be 0
        $stop.GetElementsByTagName("LogonType").Count | Should -Be 0
        $watch.Task.Settings.MultipleInstancesPolicy | Should -Be "IgnoreNew"
        $watch.Task.Settings.ExecutionTimeLimit | Should -Be "PT0S"
        $watch.Task.Triggers.BootTrigger.Enabled | Should -Be "true"
        $stop.Task.Triggers.EventTrigger.Subscription.InnerText | Should -Match "Provider\[@Name='esme'\] and EventID=2001"
        $watch.OuterXml | Should -Not -Match 'RestartOnFailure'
        $stop.Task.Actions.Exec.Arguments | Should -Match '-Mode SessionStarted'
    }

    It "backs up reset and preserves credentials, sync files and existing tasks" {
        Invoke-DiskWatcherInstall
        $backups = @(Get-ChildItem $InstallRoot -Filter 'Reset-And-Connect.ps1.watcher-*.bak')
        $backups.Count | Should -Be 1
        (Get-Content $backups[0].FullName -Raw).Trim() | Should -Be "original-reset"
        (Get-Content (Join-Path $InstallRoot "Reset-And-Connect.ps1") -Raw) | Should -Match 'Invoke-ResetDiskWatcherHook'
        foreach ($file in @("client.token", "reset-ca.crt", "egs-sync.json", "majestic-sync.json", "gta5rp-sync.json")) {
            (Get-Content (Join-Path $InstallRoot $file) -Raw).Trim() | Should -Be "preserve-$file"
        }
        Should -Invoke Register-ScheduledTask -Times 2 -Exactly -ParameterFilter { $TaskPath -eq "\IscsiReset\" }
        Should -Invoke Register-ScheduledTask -Times 0 -Exactly -ParameterFilter { $TaskPath -ne "\IscsiReset\" }
        $config = Get-WatchConfig
        $config.enabled | Should -BeTrue
        $config.PSObject.Properties.Name | Should -Not -Contain "installed_boot_id"
        (Get-WatchState (Get-WatchBootId)).install_blocked | Should -BeTrue
        Should -Invoke Set-WatcherRestrictedAcl -ParameterFilter { $Path -eq $InstallRoot -and $Directory }
    }

    It "updates idempotently while retaining the current-boot session latch" {
        Invoke-DiskWatcherInstall
        $state = Get-WatchState (Get-WatchBootId)
        $state.session_latched = $true
        Save-WatchState $state
        Invoke-DiskWatcherInstall
        (Get-WatchState (Get-WatchBootId)).session_latched | Should -BeTrue
        $script:InstallerOwnedTasks.Count | Should -Be 2
        Should -Invoke Register-ScheduledTask -Times 4 -Exactly
    }

    It "does not overwrite a same-named task owned by someone else" {
        $script:InstallerOwnedTasks = @([pscustomobject]@{
            TaskName = "Disk Watcher"; TaskPath = "\IscsiReset\"; Description = "foreign"; State = "Running"
        })
        { Invoke-DiskWatcherInstall } | Should -Throw "*another owner*"
        Should -Invoke Register-ScheduledTask -Times 0 -Exactly
        Should -Invoke Stop-ScheduledTask -Times 0 -Exactly
        (Get-Content (Join-Path $InstallRoot "Reset-And-Connect.ps1") -Raw).Trim() | Should -Be "original-reset"
    }

    It "does not install while reset is running" {
        $script:RootResetRunning = $true
        { Invoke-DiskWatcherInstall } | Should -Throw "*reset task*"
        Should -Invoke Register-ScheduledTask -Times 0 -Exactly
    }

    It "leaves protection disabled if registration fails" {
        $script:FailRegisterWatcher = $true
        { Invoke-DiskWatcherInstall } | Should -Throw "*registration failed*"
        (Get-WatchConfig).enabled | Should -BeFalse
    }

    It "uninstalls only its tasks/config and keeps protected client files and runtime" {
        Invoke-DiskWatcherInstall
        $WatcherScriptPath = Join-Path $TestDrive "removed-source.ps1"
        $Uninstall = $true
        Invoke-DiskWatcherInstall
        Test-Path (Join-Path $InstallRoot "disk-watchdog.json") | Should -BeFalse
        Test-Path (Join-Path $InstallRoot "disk-watchdog-state.json") | Should -BeTrue
        Test-Path (Join-Path $InstallRoot "client.token") | Should -BeTrue
        Test-Path (Join-Path $InstallRoot "Reset-And-Connect.ps1") | Should -BeTrue
        Should -Invoke Unregister-ScheduledTask -Times 2 -Exactly -ParameterFilter { $TaskPath -eq "\IscsiReset\" }
        Should -Invoke Unregister-ScheduledTask -Times 0 -Exactly -ParameterFilter { $TaskPath -ne "\IscsiReset\" }
    }

    It "stops the old worker and cancels legacy ownership on uninstall=<Remove>" -TestCases @(
        @{ Remove = $false }, @{ Remove = $true }
    ) {
        param($Remove)
        Invoke-DiskWatcherInstall
        $legacy = @{
            schema_version = 1; boot_id = (Get-WatchBootId); session_latched = $true
            last_event_record = 100; recent_reboots = @("discard-history")
            pending = @{
                id = "owned-reboot"; phase = "scheduled"; boot_id = (Get-WatchBootId)
                deadline_ticks = [string]([DateTime]::UtcNow.AddSeconds(30).Ticks)
            }
        }
        Write-WatchJson (Get-WatchPath "disk-watchdog-state.json") $legacy
        $process = [pscustomobject]@{ ExitCode = 0 }
        $process | Add-Member ScriptMethod WaitForExit { param($timeout) return $true }
        $process | Add-Member ScriptMethod Dispose { }
        $script:InstallerShutdownProcess = $process
        $script:OldWorkerStopped = $false
        Mock Stop-ScheduledTask { $script:OldWorkerStopped = $true }
        Mock Start-Process {
            if (-not $script:OldWorkerStopped) { throw "worker was not stopped before legacy cancellation" }
            return $script:InstallerShutdownProcess
        }
        $script:InstallerOwnedTasks[0].State = "Running"
        $Uninstall = $Remove
        Invoke-DiskWatcherInstall
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter { $ArgumentList -eq "/a" }
        Should -Invoke Stop-ScheduledTask -Times 1 -Exactly -ParameterFilter {
            $TaskName -eq "Disk Watcher" -and $TaskPath -eq "\IscsiReset\"
        }
        $state = Get-WatchState (Get-WatchBootId)
        $state.schema_version | Should -Be 2
        $state.session_latched | Should -BeTrue
        $state.PSObject.Properties.Name | Should -Not -Contain "pending"
        $state.PSObject.Properties.Name | Should -Not -Contain "recent_reboots"
        Invoke-DiskWatcherInstall
        Should -Invoke Start-Process -Times 1 -Exactly
    }

    It "never aborts an unconfirmed legacy reboot: <Case>" -TestCases @(
        @{ Case = "previous-boot" }, @{ Case = "expired" }, @{ Case = "not-accepted" }, @{ Case = "missing" }
    ) {
        param($Case)
        Invoke-DiskWatcherInstall
        $legacy = @{
            schema_version = 1; boot_id = (Get-WatchBootId); session_latched = $false; last_event_record = 0
            pending = @{
                id = "owned-reboot"; phase = "scheduled"; boot_id = (Get-WatchBootId)
                deadline_ticks = [string]([DateTime]::UtcNow.AddSeconds(30).Ticks)
            }
        }
        switch ($Case) {
            "previous-boot" { $legacy.boot_id = [string]([long]$legacy.boot_id - 1) }
            "expired" { $legacy.pending.deadline_ticks = [string]([DateTime]::UtcNow.AddSeconds(-1).Ticks) }
            "not-accepted" { $legacy.pending.phase = "scheduling" }
            "missing" { $legacy.pending = $null }
        }
        Write-WatchJson (Get-WatchPath "disk-watchdog-state.json") $legacy
        Mock Start-Process { throw "must not cancel" }
        Invoke-DiskWatcherInstall
        Should -Invoke Start-Process -Times 0 -Exactly
    }

    It "stops an interrupted legacy cancellation before copy and reconciles on retry" {
        Invoke-DiskWatcherInstall
        $legacy = @{
            schema_version = 1; boot_id = (Get-WatchBootId); session_latched = $true; last_event_record = 100
            pending = @{
                id = "owned-reboot"; phase = "scheduled"; boot_id = (Get-WatchBootId)
                deadline_ticks = [string]([DateTime]::UtcNow.AddSeconds(30).Ticks)
            }
        }
        Write-WatchJson (Get-WatchPath "disk-watchdog-state.json") $legacy
        $process = [pscustomobject]@{ ExitCode = 0 }
        $process | Add-Member ScriptMethod WaitForExit { param($timeout) return $true }
        $process | Add-Member ScriptMethod Dispose { }
        $script:InstallerShutdownProcess = $process
        Mock Start-Process { return $script:InstallerShutdownProcess }
        $script:RealInstallerWrite = ${function:Write-WatchJson}
        $script:FailCancelSave = $true
        Mock Write-WatchJson {
            if ($Value.schema_version -eq 1 -and $Value.PSObject.Properties.Name -contains "pending" -and
                $null -eq $Value.pending -and $script:FailCancelSave) {
                $script:FailCancelSave = $false
                throw "simulated failure immediately after cancellation"
            }
            & $script:RealInstallerWrite -Path $Path -Value $Value
        }
        { Invoke-DiskWatcherInstall } | Should -Throw "*after cancellation*"
        @(Get-ChildItem $InstallRoot -Filter '*.bak').Count | Should -Be 1
        $script:InstallerShutdownProcess.ExitCode = 1116 # Windows: no shutdown remains pending.
        Invoke-DiskWatcherInstall
        Should -Invoke Start-Process -Times 2 -Exactly
        (Get-WatchState (Get-WatchBootId)).session_latched | Should -BeTrue
    }
}

Describe "Disk watcher native Windows ACL" {
    It "restricts new state files to SYSTEM and Administrators" {
        if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
            Set-ItResult -Skipped -Because "Windows ACL implementation is required"
            return
        }
        $root = Join-Path $TestDrive "native-acl"
        New-Item -ItemType Directory -Path $root | Out-Null
        Set-WatcherRestrictedAcl -Path $root -Directory
        $file = Join-Path $root "state.json"
        Set-Content -LiteralPath $file '{}'
        $rules = @((Get-Acl -LiteralPath $file).Access)
        $sids = @($rules | ForEach-Object {
            $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
        } | Sort-Object -Unique)
        $sids.Count | Should -Be 2
        $sids | Should -Contain "S-1-5-18"
        $sids | Should -Contain "S-1-5-32-544"
        (Get-Acl -LiteralPath $root).AreAccessRulesProtected | Should -BeTrue
    }
}

Describe "Disk watcher native Task Scheduler registration" {
    It "validates and registers an inert SYSTEM <Mode> task" -TestCases @(
        @{ Mode = "Watch" }, @{ Mode = "SessionStarted" }
    ) {
        param($Mode)
        if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
            Set-ItResult -Skipped -Because "Native Windows Task Scheduler is required"
            return
        }
        $scheduler = New-Object -ComObject Schedule.Service
        $scheduler.Connect()
        $rootFolder = $scheduler.GetFolder("\")
        $folderName = "IscsiResetTest-" + [Guid]::NewGuid().ToString("N")
        $taskPath = "\$folderName\"
        $folder = $rootFolder.CreateFolder($folderName)
        try {
            $xmlText = New-WatcherTaskXml -Root (Join-Path $TestDrive "inert-watcher") -Action $Mode
            # TASK_VALIDATE_ONLY=1, TASK_LOGON_SERVICE_ACCOUNT=5: no registration/execution.
            $null = $folder.RegisterTask("ValidateOnly", $xmlText, 1, "S-1-5-18", $null, 5, $null)
            # Exercise the same -Xml registration overload as the installer, with no
            # credential overrides. Keep the task disabled and replace its action by exit 0.
            $xml = [xml]$xmlText
            $enabled = $xml.CreateElement("Enabled", $xml.DocumentElement.NamespaceURI)
            $enabled.InnerText = "false"
            $null = $xml.Task.Settings.AppendChild($enabled)
            $xml.Task.Actions.Exec.Arguments = '-NoProfile -NonInteractive -Command "exit 0"'
            $task = ScheduledTasks\Register-ScheduledTask -TaskPath $taskPath -TaskName "InertWatcher" `
                -Xml $xml.OuterXml -Force -ErrorAction Stop
            [string]$task.State | Should -Be "Disabled"
            [string]$task.Principal.LogonType | Should -Be "ServiceAccount"
            $user = [string]$task.Principal.UserId
            if ($user -notmatch '^S-1-') {
                $user = (New-Object Security.Principal.NTAccount($user)).Translate(
                    [Security.Principal.SecurityIdentifier]).Value
            }
            $user | Should -Be "S-1-5-18"
            $export = [xml](ScheduledTasks\Export-ScheduledTask -TaskPath $taskPath -TaskName "InertWatcher")
            $export.Task.Principals.Principal.UserId | Should -Be "S-1-5-18"
            $export.GetElementsByTagName("LogonType").Count | Should -Be 0
            $export.Task.Settings.MultipleInstancesPolicy | Should -Be "IgnoreNew"
            $expectedLimit = if ($Mode -eq "Watch") { "PT0S" } else { "PT1M" }
            $export.Task.Settings.ExecutionTimeLimit | Should -Be $expectedLimit
            if ($Mode -eq "Watch") {
                $export.GetElementsByTagName("BootTrigger").Count | Should -Be 1
            } else {
                $export.GetElementsByTagName("EventTrigger").Count | Should -Be 1
                $export.GetElementsByTagName("Subscription")[0].InnerText | Should -Match 'EventID=2001'
            }
        } finally {
            $task = ScheduledTasks\Get-ScheduledTask -TaskPath $taskPath -TaskName "InertWatcher" `
                -ErrorAction SilentlyContinue
            if ($null -ne $task) {
                ScheduledTasks\Unregister-ScheduledTask -TaskPath $taskPath -TaskName "InertWatcher" `
                    -Confirm:$false -ErrorAction Stop
            }
            $rootFolder.DeleteFolder($folderName, 0)
        }
    }
}
