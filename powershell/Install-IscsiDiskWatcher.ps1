#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$InstallRoot = "C:\ProgramData\IscsiReset",
    [string]$ClientScriptPath = "",
    [string]$WatcherScriptPath = "",
    [switch]$Uninstall,
    [switch]$NoMain
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
if (-not $ClientScriptPath) { $ClientScriptPath = Join-Path $PSScriptRoot "Reset-And-Connect.ps1" }
if (-not $WatcherScriptPath) { $WatcherScriptPath = Join-Path $PSScriptRoot "Watch-IscsiDisks.ps1" }
$script:DiskWatcherOwner = "IscsiReset disk watcher; managed by Install-IscsiDiskWatcher.ps1"
$script:DiskWatcherTaskPath = "\IscsiReset\"

function Assert-WatcherAdministrator {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) -or
        -not [Environment]::Is64BitProcess) { throw "Use elevated 64-bit Windows PowerShell 5.1" }
}

function Set-WatcherRestrictedAcl {
    param([string]$Path, [switch]$Directory)
    if (((Get-Item -LiteralPath $Path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Watcher paths must not be reparse points"
    }
    if ($Directory) { $acl = New-Object Security.AccessControl.DirectorySecurity }
    else { $acl = New-Object Security.AccessControl.FileSecurity }
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($value in @("S-1-5-18", "S-1-5-32-544")) {
        $sid = New-Object Security.Principal.SecurityIdentifier($value)
        if ($Directory) {
            $rule = New-Object Security.AccessControl.FileSystemAccessRule(
                $sid, "FullControl", "ContainerInherit, ObjectInherit", "None", "Allow")
        } else { $rule = New-Object Security.AccessControl.FileSystemAccessRule($sid, "FullControl", "Allow") }
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Get-OwnedWatcherTasks {
    $tasks = @()
    foreach ($name in @("Disk Watcher", "Stop Disk Watcher On Session")) {
        $task = Get-ScheduledTask -TaskPath $script:DiskWatcherTaskPath -TaskName $name -ErrorAction SilentlyContinue
        if ($null -ne $task) {
            if ([string]$task.Description -ne $script:DiskWatcherOwner) { throw "Watcher task name belongs to another owner" }
            $tasks += $task
        }
    }
    return $tasks
}

function New-WatcherTaskXml {
    param([string]$Root, [ValidateSet("Watch", "SessionStarted")][string]$Action)
    $powerShell = [Security.SecurityElement]::Escape(
        (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"))
    $arguments = [Security.SecurityElement]::Escape(
        ('-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -InstallRoot "{1}" -Mode {2}' -f
            (Join-Path $Root "Watch-IscsiDisks.ps1"), $Root, $Action))
    $trigger = if ($Action -eq "Watch") { '<BootTrigger><Enabled>true</Enabled></BootTrigger>' } else {
        '<EventTrigger><Enabled>true</Enabled><Subscription><![CDATA[<QueryList><Query Id="0" Path="Application"><Select Path="Application">*[System[Provider[@Name=''esme''] and EventID=2001]]</Select></Query></QueryList>]]></Subscription></EventTrigger>'
    }
    $limit = if ($Action -eq "Watch") { "PT0S" } else { "PT1M" }
    # SYSTEM uses its SID without LogonType in XML. ServiceAccount is an API enum,
    # not an allowed value of the Task Scheduler XML logonType simple type.
    return @"
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>$($script:DiskWatcherOwner)</Description></RegistrationInfo>
  <Triggers>$trigger</Triggers>
  <Principals><Principal id="System"><UserId>S-1-5-18</UserId><RunLevel>HighestAvailable</RunLevel></Principal></Principals>
  <Settings><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy><DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries><StopIfGoingOnBatteries>false</StopIfGoingOnBatteries><AllowHardTerminate>true</AllowHardTerminate><StartWhenAvailable>true</StartWhenAvailable><ExecutionTimeLimit>$limit</ExecutionTimeLimit></Settings>
  <Actions Context="System"><Exec><Command>$powerShell</Command><Arguments>$arguments</Arguments></Exec></Actions>
</Task>
"@
}

function Ensure-WatcherTaskFolder {
    $scheduler = New-Object -ComObject Schedule.Service
    $scheduler.Connect()
    $root = $scheduler.GetFolder("\")
    if (-not @($root.GetFolders(0) | Where-Object Name -eq "IscsiReset").Count) {
        $null = $root.CreateFolder("IscsiReset")
    }
}

function Stop-OwnedWatcherTasks {
    param($Tasks)
    foreach ($task in @($Tasks)) {
        if ($task.State -eq "Running") {
            Stop-ScheduledTask -TaskPath $task.TaskPath -TaskName $task.TaskName -ErrorAction Stop
        }
    }
}

function Cancel-LegacyWatcherReboot {
    param([string]$BootId)
    # Upgrade/uninstall only: the new worker never queues or cancels a delayed reboot.
    $path = Get-WatchPath "disk-watchdog-state.json"
    if (-not (Test-Path -LiteralPath $path)) { return }
    $legacy = Read-WatchJson $path
    if ($legacy.schema_version -ne 1 -or [string]$legacy.boot_id -ne $BootId) { return }
    if ($null -eq $legacy.pending -or $legacy.pending.phase -ne "scheduled" -or
        [string]$legacy.pending.boot_id -ne $BootId -or
        [long]$legacy.pending.deadline_ticks -le (Get-WatchNowTicks) -or
        [string]::IsNullOrWhiteSpace([string]$legacy.pending.id)) { return }
    $process = Start-Process -FilePath (Join-Path $env:SystemRoot "System32/shutdown.exe") `
        -ArgumentList "/a" -PassThru -WindowStyle Hidden -ErrorAction Stop
    try {
        if (-not $process.WaitForExit(5000) -or $process.ExitCode -notin @(0, 1116)) {
            throw "Legacy reboot cancellation failed"
        }
    } finally { $process.Dispose() }
    # Persist cancellation before any further step, so an interrupted upgrade is repeatable.
    $legacy.pending = $null
    Write-WatchJson $path $legacy
    Write-WatchLog "legacy_reboot_cancelled"
}

function Invoke-DiskWatcherInstall {
    Assert-WatcherAdministrator
    $tasks = @(Get-OwnedWatcherTasks)
    if (-not [IO.Path]::IsPathRooted($InstallRoot) -or $InstallRoot -match '["\r\n]' -or
        [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\', '/') -eq [IO.Path]::GetPathRoot($InstallRoot).TrimEnd('\', '/')) {
        throw "Use a dedicated absolute install directory"
    }
    $installedReset = Join-Path $InstallRoot "Reset-And-Connect.ps1"
    if (-not (Test-Path -LiteralPath $installedReset -PathType Leaf)) { throw "Install the reset client first" }
    $resetTask = Get-ScheduledTask -TaskPath "\" -TaskName "iSCSI Reset and Connect" -ErrorAction SilentlyContinue
    if ($null -ne $resetTask -and $resetTask.State -eq "Running") { throw "Wait for the reset task to finish" }
    if ($Uninstall -and -not (Test-Path -LiteralPath $WatcherScriptPath -PathType Leaf)) {
        $WatcherScriptPath = Join-Path $InstallRoot "Watch-IscsiDisks.ps1"
    }
    if (-not (Test-Path -LiteralPath $WatcherScriptPath -PathType Leaf)) { throw "Watcher source missing" }
    if (-not $Uninstall) {
        if (-not (Test-Path -LiteralPath $ClientScriptPath -PathType Leaf) -or
            (Get-Content -LiteralPath $ClientScriptPath -Raw) -notmatch 'function Invoke-ResetDiskWatcherHook') {
            throw "Updated reset client with watcher integration is required"
        }
    }
    Set-WatcherRestrictedAcl -Path $InstallRoot -Directory
    New-Item -ItemType Directory -Path (Join-Path $InstallRoot "logs") -Force | Out-Null
    Set-WatcherRestrictedAcl -Path (Join-Path $InstallRoot "logs") -Directory
    . $WatcherScriptPath -InstallRoot $InstallRoot -NoMain
    $bootId = Get-WatchBootId
    $statePath = Get-WatchPath "disk-watchdog-state.json"
    Invoke-WatchLocked {
        # Wait out the old worker's critical section before stopping it. Never interrupt
        # it between shutdown acceptance and persisting its legacy ownership record.
        Stop-OwnedWatcherTasks -Tasks $tasks
        Cancel-LegacyWatcherReboot -BootId $bootId
        $state = Get-WatchState -BootId $bootId
        $state.arm = $null; $state.incident = $null; $state.failures = 0
        $state.reboot_requested = $false
        if (-not $Uninstall) { $state.install_blocked = $true }
        Save-WatchState $state
    }
    $configPath = Get-WatchPath "disk-watchdog.json"
    if ($Uninstall) {
        foreach ($task in $tasks) {
            Unregister-ScheduledTask -TaskPath $task.TaskPath -TaskName $task.TaskName `
                -Confirm:$false -ErrorAction Stop
        }
        if (Test-Path -LiteralPath $configPath) { Remove-Item -LiteralPath $configPath -Force }
        Write-Host "Removed disk watcher tasks and configuration. Runtime files, logs and reset settings were retained."
        return
    }
    # Failure during file copy or task registration leaves the feature disabled.
    $config = @{ schema_version = 1; enabled = $false }
    Write-WatchJson -Path $configPath -Value $config
    Set-WatcherRestrictedAcl -Path $configPath
    $backup = $installedReset + ".watcher-" + [Guid]::NewGuid().ToString("N") + ".bak"
    Copy-Item -LiteralPath $installedReset -Destination $backup -ErrorAction Stop
    Set-WatcherRestrictedAcl -Path $backup
    foreach ($entry in @(
        @{ Source = $ClientScriptPath; Destination = $installedReset },
        @{ Source = $WatcherScriptPath; Destination = (Join-Path $InstallRoot "Watch-IscsiDisks.ps1") }
    )) {
        if ([IO.Path]::GetFullPath($entry.Source) -ne [IO.Path]::GetFullPath($entry.Destination)) {
            Copy-Item -LiteralPath $entry.Source -Destination $entry.Destination -Force -ErrorAction Stop
        }
        Set-WatcherRestrictedAcl -Path $entry.Destination
    }
    Ensure-WatcherTaskFolder
    Register-ScheduledTask -TaskPath $script:DiskWatcherTaskPath -TaskName "Disk Watcher" `
        -Xml (New-WatcherTaskXml -Root $InstallRoot -Action Watch) -Force -ErrorAction Stop | Out-Null
    Register-ScheduledTask -TaskPath $script:DiskWatcherTaskPath -TaskName "Stop Disk Watcher On Session" `
        -Xml (New-WatcherTaskXml -Root $InstallRoot -Action SessionStarted) -Force -ErrorAction Stop | Out-Null
    $config.enabled = $true
    Write-WatchJson -Path $configPath -Value $config
    Set-WatcherRestrictedAcl -Path $statePath
    Write-Host "Installed disk watcher. Reboot; monitoring arms only after a successful reset in the next boot."
}

if (-not $NoMain) { Invoke-DiskWatcherInstall }
