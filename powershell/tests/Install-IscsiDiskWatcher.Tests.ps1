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
        foreach ($file in @("client.token", "egs-sync.json", "majestic-sync.json", "gta5rp-sync.json")) {
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
        foreach ($file in @("client.token", "egs-sync.json", "majestic-sync.json", "gta5rp-sync.json")) {
            (Get-Content (Join-Path $InstallRoot $file) -Raw).Trim() | Should -Be "preserve-$file"
        }
        Should -Invoke Register-ScheduledTask -Times 2 -Exactly -ParameterFilter { $TaskPath -eq "\IscsiReset\" }
        Should -Invoke Register-ScheduledTask -Times 0 -Exactly -ParameterFilter { $TaskPath -ne "\IscsiReset\" }
        $config = Get-WatchConfig
        $config.enabled | Should -BeTrue
        $config.installed_boot_id | Should -Be (Get-WatchBootId)
        Should -Invoke Set-WatcherRestrictedAcl -ParameterFilter { $Path -eq $InstallRoot -and $Directory }
    }

    It "updates idempotently while retaining the reboot budget" {
        Invoke-DiskWatcherInstall
        $state = Get-WatchState (Get-WatchBootId)
        $state.recent_reboots = @([pscustomobject]@{ id = "previous"; ticks = [string]([DateTime]::UtcNow.AddMinutes(-1).Ticks) })
        Save-WatchState $state
        Invoke-DiskWatcherInstall
        @((Get-WatchState (Get-WatchBootId)).recent_reboots).Count | Should -Be 1
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

    It "uninstalls only its tasks/config and keeps protected client files and history" {
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

    It "cancels its own accepted pending reboot before stopping tasks on uninstall" {
        Invoke-DiskWatcherInstall
        $state = Get-WatchState (Get-WatchBootId)
        $state.pending = [pscustomobject]@{
            id = "owned-reboot"; phase = "scheduled"; boot_id = $state.boot_id
            deadline_ticks = [string]([DateTime]::UtcNow.AddSeconds(30).Ticks)
        }
        Save-WatchState $state
        $process = [pscustomobject]@{ ExitCode = 0 }
        $process | Add-Member ScriptMethod WaitForExit { param($timeout) return $true }
        $process | Add-Member ScriptMethod Dispose { }
        $script:InstallerShutdownProcess = $process
        Mock Start-Process { return $script:InstallerShutdownProcess }
        $script:InstallerOwnedTasks[0].State = "Running"
        $Uninstall = $true
        Invoke-DiskWatcherInstall
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter { $ArgumentList -eq "/a" }
        Should -Invoke Stop-ScheduledTask -Times 1 -Exactly -ParameterFilter {
            $TaskName -eq "Disk Watcher" -and $TaskPath -eq "\IscsiReset\"
        }
        (Get-WatchState (Get-WatchBootId)).pending | Should -BeNullOrEmpty
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
