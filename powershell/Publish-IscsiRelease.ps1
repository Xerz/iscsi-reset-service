[CmdletBinding()]
param(
    [ValidateSet("Disconnect", "Reconnect")][string]$Action = "Disconnect",
    [string]$ManifestPath = "C:\ProgramData\IscsiResetPublisher\publisher.json",
    [string]$PendingPath = "C:\ProgramData\IscsiResetPublisher\publisher.pending.json",
    [string]$EgsSyncConfigPath = "",
    [string]$EgsManifestDirectory = "C:\ProgramData\Epic\EpicGamesLauncher\Data\Manifests",
    [string]$EgsProgramDataPath = "C:\ProgramData\Epic\EpicGamesLauncher\Data",
    [string]$EgsLauncherInstalledPath =
        "C:\ProgramData\Epic\UnrealEngineLauncher\LauncherInstalled.dat",
    [string]$EgsSharedInstallDbPath =
        "C:\ProgramData\Epic\EpicOnlineServicesShared\InstallHelper\InstalledItems",
    [string]$MajesticSyncConfigPath = "",
    [switch]$PassThruExitCode,
    [switch]$NoMain
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
$script:DefaultPublisherEgsSyncConfigPath = Join-Path $PSScriptRoot "egs-sync.json"
$script:DefaultPublisherMajesticSyncConfigPath = Join-Path $PSScriptRoot "majestic-sync.json"

function Resolve-PublisherEgsSyncConfigPath {
    param([AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $script:DefaultPublisherEgsSyncConfigPath
    }
    return $Path
}

$EgsSyncConfigPath = Resolve-PublisherEgsSyncConfigPath -Path $EgsSyncConfigPath

function Resolve-PublisherMajesticSyncConfigPath {
    param([AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $script:DefaultPublisherMajesticSyncConfigPath
    }
    return $Path
}

$MajesticSyncConfigPath = Resolve-PublisherMajesticSyncConfigPath `
    -Path $MajesticSyncConfigPath

function Normalize-PublisherDiskId {
    param([Parameter(Mandatory = $true)][string]$Value)
    $normalized = ($Value -replace "\s", "").ToLowerInvariant()
    if ($normalized.StartsWith("0x")) { return $normalized.Substring(2) }
    return $normalized
}

function Get-EgsManifestSyncMode {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return "Disabled" }
    $config = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ([int]$config.schema_version -eq 1 -and $config.enabled -is [bool]) {
        if ([bool]$config.enabled) { return "Enabled" }
        return "Disabled"
    }
    if ([int]$config.schema_version -eq 2 -and
        [string]$config.mode -in @("disabled", "enabled", "aggressive")) {
        switch ([string]$config.mode) {
            "disabled" { return "Disabled" }
            "enabled" { return "Enabled" }
            "aggressive" { return "Aggressive" }
        }
    }
    throw "Epic Games manifest sync config is invalid: $Path"
}

function Get-EgsManifestSyncEnabled {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-EgsManifestSyncMode -Path $Path) -ne "Disabled"
}

function Get-MajesticSyncConfig {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or
        -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{
            Present = $false
            Enabled = $false
            UserSid = ""
            ProfilePath = ""
        }
    }
    $config = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ([int]$config.schema_version -ne 1 -or
        [string]$config.mode -notin @("disabled", "enabled")) {
        throw "Majestic Launcher settings sync config is invalid: $Path"
    }
    $enabled = [string]$config.mode -eq "enabled"
    $sid = [string]$config.user_sid
    $profilePath = [string]$config.profile_path
    if ($enabled -and
        ($sid -notmatch '^S-1-[0-9]+(?:-[0-9]+)+$' -or
        $sid -eq "S-1-5-18" -or
        [string]::IsNullOrWhiteSpace($profilePath) -or
        -not [IO.Path]::IsPathRooted($profilePath))) {
        throw "Majestic Launcher settings sync user profile is invalid"
    }
    return [pscustomobject]@{
        Present = $true
        Enabled = $enabled
        UserSid = $sid
        ProfilePath = $profilePath
    }
}

function Stop-MajesticLauncherProcesses {
    param([int]$GraceSeconds = 15)
    $running = @(Get-Process -Name "Majestic Launcher" -ErrorAction SilentlyContinue)
    foreach ($process in $running) {
        try { $process.CloseMainWindow() | Out-Null } catch { }
    }
    for ($second = 0; $second -lt $GraceSeconds; $second++) {
        if (@(Get-Process -Name "Majestic Launcher" `
            -ErrorAction SilentlyContinue).Count -eq 0) { return }
        Start-Sleep -Seconds 1
    }
    foreach ($process in @(Get-Process -Name "Majestic Launcher" `
        -ErrorAction SilentlyContinue)) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 1
    if (@(Get-Process -Name "Majestic Launcher" `
        -ErrorAction SilentlyContinue).Count -ne 0) {
        throw "Majestic Launcher processes could not be stopped"
    }
}

function Assert-MajesticLauncherStopped {
    if (@(Get-Process -Name "Majestic Launcher" `
        -ErrorAction SilentlyContinue).Count -ne 0) {
        throw "Majestic Launcher restarted during settings export"
    }
}

function Open-MajesticUserHive {
    param(
        [Parameter(Mandatory = $true)][string]$UserSid,
        [Parameter(Mandatory = $true)][string]$ProfilePath
    )
    if (Test-Path -LiteralPath "Registry::HKEY_USERS\$UserSid") {
        return [pscustomobject]@{ RootName = $UserSid; LoadedByHelper = $false }
    }
    $hivePath = Join-Path $ProfilePath "NTUSER.DAT"
    if (-not (Test-Path -LiteralPath $hivePath -PathType Leaf)) {
        throw "Majestic Launcher user NTUSER.DAT does not exist"
    }
    $hiveFile = Get-Item -LiteralPath $hivePath -Force
    if (([int]$hiveFile.Attributes -band [int][IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Majestic Launcher user NTUSER.DAT must not be a reparse point"
    }
    $rootName = "IscsiResetMajestic_" + [Guid]::NewGuid().ToString("N")
    & reg.exe load "HKU\$rootName" $hivePath | Out-Null
    if ($LASTEXITCODE -ne 0 -or
        -not (Test-Path -LiteralPath "Registry::HKEY_USERS\$rootName")) {
        throw "Majestic Launcher user registry hive could not be loaded"
    }
    return [pscustomobject]@{ RootName = $rootName; LoadedByHelper = $true }
}

function Close-MajesticUserHive {
    param([Parameter(Mandatory = $true)]$Hive)
    if (-not [bool]$Hive.LoadedByHelper) { return }
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
    & reg.exe unload "HKU\$($Hive.RootName)" | Out-Null
    if ($LASTEXITCODE -ne 0 -or
        (Test-Path -LiteralPath "Registry::HKEY_USERS\$($Hive.RootName)")) {
        throw "Majestic Launcher user registry hive could not be unloaded"
    }
}

function Get-MajesticRegistryValuesFromRoot {
    param([Parameter(Mandatory = $true)][string]$RootName)
    $users = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::Users,
        [Microsoft.Win32.RegistryView]::Default
    )
    $key = $null
    try {
        $key = $users.OpenSubKey("$RootName\Software\MAJESTIC-LAUNCHER", $false)
        if ($null -eq $key) { throw "Majestic Launcher registry key does not exist" }
        $values = [ordered]@{}
        foreach ($name in @("lastVisitedServerID", "game_disk")) {
            if ($key.GetValueKind($name) -ne [Microsoft.Win32.RegistryValueKind]::String) {
                throw "Majestic Launcher registry value is not REG_SZ: $name"
            }
            $value = [string]$key.GetValue(
                $name,
                $null,
                [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
            )
            if ([string]::IsNullOrWhiteSpace($value) -or $value.Length -gt 1024) {
                throw "Majestic Launcher registry value is invalid: $name"
            }
            $values[$name] = $value
        }
        return [pscustomobject]$values
    } finally {
        if ($null -ne $key) { $key.Dispose() }
        $users.Dispose()
    }
}

function Get-MajesticRegistryValues {
    param([Parameter(Mandatory = $true)]$Config)
    $hive = Open-MajesticUserHive -UserSid $Config.UserSid `
        -ProfilePath $Config.ProfilePath
    $failure = $null
    try {
        return Get-MajesticRegistryValuesFromRoot -RootName $hive.RootName
    } catch {
        $failure = $_
        throw
    } finally {
        try { Close-MajesticUserHive -Hive $hive } catch {
            if ($null -eq $failure) { throw }
        }
    }
}

function Get-EgsSha256Hex {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return (($algorithm.ComputeHash($Bytes) | ForEach-Object {
            $_.ToString("x2")
        }) -join "")
    } finally {
        $algorithm.Dispose()
    }
}

function Get-EgsFileSha256Hex {
    param([Parameter(Mandatory = $true)][string]$Path)
    $stream = [IO.File]::OpenRead($Path)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return (($algorithm.ComputeHash($stream) | ForEach-Object {
            $_.ToString("x2")
        }) -join "")
    } finally {
        $algorithm.Dispose()
        $stream.Dispose()
    }
}

function ConvertFrom-EgsJsonBytes {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)
    $json = [Text.Encoding]::UTF8.GetString($Bytes)
    if ($json.Length -gt 0 -and [int]$json[0] -eq 0xFEFF) {
        $json = $json.Substring(1)
    }
    return (ConvertFrom-Json -InputObject $json)
}

function ConvertTo-EgsCanonicalPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { throw "Epic Games path is empty" }
    $candidate = $Path.Trim().Replace("/", "\")
    if ($candidate -match "^[A-Za-z]:\\") {
        if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
            return [IO.Path]::GetFullPath($candidate).TrimEnd([char[]]@(92))
        }
        return $candidate.TrimEnd([char[]]@(92))
    }
    $separators = [char[]]@(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    )
    return [IO.Path]::GetFullPath($Path).TrimEnd($separators)
}

function Test-EgsPathWithinRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$RootPath
    )
    $candidate = ConvertTo-EgsCanonicalPath $Path
    $root = ConvertTo-EgsCanonicalPath $RootPath
    if ($candidate.Equals($root, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    $separator = if ($candidate -match "^[A-Za-z]:\\") { "\" } else {
        [IO.Path]::DirectorySeparatorChar
    }
    return $candidate.StartsWith(
        $root.TrimEnd([char[]]@(92, 47)) + $separator,
        [StringComparison]::OrdinalIgnoreCase
    )
}

function Get-RequiredEgsString {
    param(
        [Parameter(Mandatory = $true)]$Item,
        [Parameter(Mandatory = $true)][string]$Name
    )
    if ($Item.PSObject.Properties.Name -notcontains $Name) {
        throw "Epic Games manifest is missing $Name"
    }
    $value = [string]$Item.$Name
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "Epic Games manifest has an empty $Name"
    }
    return $value
}

function Test-EgsInstallationId {
    param([Parameter(Mandatory = $true)][string]$Value)
    return $Value -match "^[0-9A-Fa-f]{16,64}$"
}

function Test-EgsWarningFlag {
    param($Value)
    if ($Value -is [bool]) { return [bool]$Value }
    return [string]::Equals(
        [string]$Value,
        "true",
        [StringComparison]::OrdinalIgnoreCase
    )
}

function Test-EgsDirectoryHasEntries {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
    return $null -ne (Get-ChildItem -LiteralPath $Path -Force | Select-Object -First 1)
}

function Get-PublisherEgsStateWarnings {
    param(
        [Parameter(Mandatory = $true)]$Item,
        [Parameter(Mandatory = $true)][string]$InstallLocation
    )
    $warnings = @()
    if ($Item.PSObject.Properties.Name -contains "bIsIncompleteInstall" -and
        (Test-EgsWarningFlag $Item.bIsIncompleteInstall)) {
        $warnings += "item_incomplete"
    }
    if ($Item.PSObject.Properties.Name -contains "bNeedsValidation" -and
        (Test-EgsWarningFlag $Item.bNeedsValidation)) {
        $warnings += "item_needs_validation"
    }
    $egstore = Join-Path $InstallLocation ".egstore"
    if (Test-EgsDirectoryHasEntries (Join-Path $egstore "bps")) {
        $warnings += "bps_nonempty"
    }
    if (Test-EgsDirectoryHasEntries (Join-Path $egstore "Pending")) {
        $warnings += "pending_nonempty"
    }
    return @($warnings)
}

function Stop-EgsLauncherProcesses {
    param([int]$GraceSeconds = 15)
    $names = @("EpicGamesLauncher", "EpicWebHelper")
    $launcher = @(Get-Process -Name $names -ErrorAction SilentlyContinue)
    foreach ($process in @($launcher | Where-Object { $_.ProcessName -eq "EpicGamesLauncher" })) {
        try { $process.CloseMainWindow() | Out-Null } catch { }
    }

    for ($second = 0; $second -lt $GraceSeconds; $second++) {
        if (@(Get-Process -Name $names -ErrorAction SilentlyContinue).Count -eq 0) { return }
        Start-Sleep -Seconds 1
    }

    foreach ($process in @(Get-Process -Name $names -ErrorAction SilentlyContinue)) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 1
    if (@(Get-Process -Name $names -ErrorAction SilentlyContinue).Count -ne 0) {
        throw "Epic Games Launcher processes could not be stopped"
    }
}

function Assert-EgsLauncherStopped {
    $running = @(Get-Process -Name @("EpicGamesLauncher", "EpicWebHelper") `
        -ErrorAction SilentlyContinue)
    if ($running.Count -ne 0) { throw "Epic Games Launcher restarted during manifest export" }
}

function Get-EgsSharedInstallHelperProcesses {
    param([Parameter(Mandatory = $true)][string]$InstallDbPath)
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { return @() }
    $needle = $InstallDbPath.TrimEnd([char[]]@(92, 47)).Replace("/", "\")
    try {
        return @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop | Where-Object {
            $commandLine = ([string]$_.CommandLine).Replace("/", "\")
            if ([string]::IsNullOrWhiteSpace($commandLine)) { return $false }
            $match = [regex]::Match(
                $commandLine,
                '--installationdbdir(?:\s*=\s*|\s+)(?:"([^"]+)"|([^\s"]+))',
                [Text.RegularExpressions.RegexOptions]::IgnoreCase
            )
            if (-not $match.Success) { return $false }
            $candidate = if ($match.Groups[1].Success) {
                $match.Groups[1].Value
            } else {
                $match.Groups[2].Value
            }
            [string]::Equals(
                $candidate.TrimEnd([char[]]@(92, 47)),
                $needle,
                [StringComparison]::OrdinalIgnoreCase
            )
        })
    } catch {
        throw "Epic Games InstallHelper process state could not be verified"
    }
}

function Wait-EgsSharedInstallDbIdle {
    param(
        [Parameter(Mandatory = $true)][string]$InstallDbPath,
        [int]$TimeoutSeconds = 15
    )
    for ($second = 0; $second -le $TimeoutSeconds; $second++) {
        if (@(Get-EgsSharedInstallHelperProcesses `
            -InstallDbPath $InstallDbPath).Count -eq 0) { return }
        if ($second -lt $TimeoutSeconds) { Start-Sleep -Seconds 1 }
    }
    throw "Epic Games shared installation database is still in use"
}

function Get-PublisherVolumeMappings {
    param(
        [Parameter(Mandatory = $true)]$ExpectedVolumes,
        [Parameter(Mandatory = $true)]$Disks
    )
    $mappings = @()
    foreach ($expected in $ExpectedVolumes) {
        $expectedId = Normalize-PublisherDiskId ([string]$expected.disk_unique_id)
        $matches = @($Disks | Where-Object {
            (Normalize-PublisherDiskId ([string]$_.UniqueId)) -eq $expectedId
        })
        if ($matches.Count -ne 1) {
            throw "Expected exactly one Publisher disk for volume $($expected.name)"
        }
        $partitions = @(Get-Partition -DiskNumber $matches[0].Number | Where-Object {
            $_.Type -notin @("Reserved", "System", "Recovery")
        })
        if ($partitions.Count -ne 1 -or
            [string]::IsNullOrWhiteSpace([string]$partitions[0].DriveLetter)) {
            throw "Publisher volume $($expected.name) must have one mounted data partition"
        }
        $letter = ([string]$partitions[0].DriveLetter).ToUpperInvariant()
        if ($letter -notmatch "^[A-Z]$") {
            throw "Publisher volume $($expected.name) has an invalid drive letter"
        }
        $mappings += [pscustomobject]@{
            Name = [string]$expected.name
            Disk = $matches[0]
            DriveLetter = $letter
            RootPath = "$letter`:\"
        }
    }
    return $mappings
}

function Get-PublisherEgsVolumeMappings {
    param(
        [Parameter(Mandatory = $true)]$ExpectedVolumes,
        [Parameter(Mandatory = $true)]$Disks
    )
    return @(Get-PublisherVolumeMappings -ExpectedVolumes $ExpectedVolumes -Disks $Disks)
}

function Get-PublisherMajesticBundlePath {
    param(
        [Parameter(Mandatory = $true)]$VolumeMapping,
        [ValidateSet(1, 2)][int]$SchemaVersion = 2
    )
    return Join-Path $VolumeMapping.RootPath `
        ".iscsi-reset\majestic-launcher-settings.v$SchemaVersion.json"
}

function Get-PublisherMajesticBackupPayloadPath {
    param(
        [Parameter(Mandatory = $true)]$VolumeMapping,
        [ValidateSet("active", "staging")][string]$Kind = "active"
    )
    $leaf = switch ($Kind) {
        "active" { "majestic-launcher-backup" }
        "staging" { ".majestic-launcher-backup.staging" }
    }
    return Join-Path $VolumeMapping.RootPath (".iscsi-reset\" + $leaf)
}

function Get-PublisherMajesticBackupPreviousPath {
    param([Parameter(Mandatory = $true)][string]$BackupPath)
    return Join-Path (Split-Path $BackupPath -Parent) `
        ".iscsi-reset-majestic-backup.previous"
}

function Assert-PublisherMajesticHelperDirectory {
    param(
        [Parameter(Mandatory = $true)]$VolumeMapping,
        [switch]$Create
    )
    $path = Join-Path $VolumeMapping.RootPath ".iscsi-reset"
    if (-not (Test-Path -LiteralPath $path)) {
        if (-not $Create) { return }
        New-Item -ItemType Directory -Path $path | Out-Null
    }
    $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
    if (-not $item.PSIsContainer -or
        (([int]$item.Attributes -band [int][IO.FileAttributes]::ReparsePoint) -ne 0)) {
        throw "Majestic Launcher helper-owned root is unsafe"
    }
}

function Test-MajesticBackupLeafName {
    param([Parameter(Mandatory = $true)][string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name) -or $Name.Length -gt 255 -or
        $Name -in @(".", "..") -or $Name -match '[\\/:]' -or
        [IO.Path]::GetFileName($Name) -cne $Name) {
        return $false
    }
    return $true
}

function Get-PublisherMajesticFileBytes {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $true)][Int64]$MaximumBytes,
        [switch]$RequireJson
    )
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or
        (([int]$item.Attributes -band [int][IO.FileAttributes]::ReparsePoint) -ne 0) -or
        [Int64]$item.Length -lt 1 -or [Int64]$item.Length -gt $MaximumBytes) {
        throw "Majestic Launcher $Description is unsafe or exceeds its size limit"
    }
    $bytes = [IO.File]::ReadAllBytes($item.FullName)
    if ($RequireJson) {
        try {
            $strictUtf8 = New-Object Text.UTF8Encoding($false, $true)
            $strictUtf8.GetString($bytes) | ConvertFrom-Json | Out-Null
        } catch {
            throw "Majestic Launcher $Description is not valid UTF-8 JSON"
        }
    }
    return $bytes
}

function New-PublisherMajesticFilePayload {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)
    return [ordered]@{
        length = [Int64]$Bytes.Length
        sha256 = Get-EgsSha256Hex $Bytes
        base64 = [Convert]::ToBase64String($Bytes)
    }
}

function Get-PublisherMajesticPrefsCapture {
    param([Parameter(Mandatory = $true)]$Config)
    $path = Join-Path $Config.ProfilePath `
        "AppData\Roaming\majestic-launcher\prefs.latest.json"
    $bytes = Get-PublisherMajesticFileBytes -Path $path `
        -Description "prefs.latest.json" -MaximumBytes 1MB -RequireJson
    try {
        $strictUtf8 = New-Object Text.UTF8Encoding($false, $true)
        $prefs = $strictUtf8.GetString($bytes) | ConvertFrom-Json
    } catch {
        throw "Majestic Launcher prefs.latest.json is not valid UTF-8 JSON"
    }
    $gameDisk = ([string]$prefs.gameDisk).Trim().ToUpperInvariant()
    if ($gameDisk -notmatch '^[D-Z]:$') {
        throw "Majestic Launcher prefs.latest.json gameDisk is missing or invalid"
    }
    return [pscustomobject]@{ Bytes = $bytes; GameDisk = $gameDisk }
}

function Get-PublisherMajesticAnchorVolume {
    param(
        [Parameter(Mandatory = $true)]$VolumeMappings,
        [Parameter(Mandatory = $true)][string]$GameDisk
    )
    $letter = $GameDisk.Substring(0, 1)
    $matches = @($VolumeMappings | Where-Object {
        $candidate = ([string]$_.DriveLetter).Trim().ToUpperInvariant()
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            $root = [string]$_.RootPath
            if ($root -match '^([D-Zd-z]):[\\/]') {
                $candidate = $Matches[1].ToUpperInvariant()
            }
        }
        $candidate -ceq $letter
    })
    if ($matches.Count -ne 1) {
        throw "Majestic Launcher gameDisk must match exactly one Publisher volume"
    }
    return $matches[0]
}

function Get-PublisherMajesticBackupIndex {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$MaximumFileCount = 64,
        [Int64]$MaximumTotalBytes = 8GB,
        [Int64]$MaximumFileBytes = 4GB
    )
    $root = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (-not $root.PSIsContainer -or
        (([int]$root.Attributes -band [int][IO.FileAttributes]::ReparsePoint) -ne 0)) {
        throw "Majestic Launcher backup directory is unsafe"
    }
    $children = @(Get-ChildItem -LiteralPath $root.FullName -Force | Sort-Object Name)
    if ($children.Count -lt 1 -or $children.Count -gt $MaximumFileCount) {
        throw "Majestic Launcher backup directory file count is invalid"
    }
    $files = @()
    $seen = @{}
    $total = [Int64]0
    foreach ($item in $children) {
        $name = [string]$item.Name
        if ($item.PSIsContainer) {
            throw "Majestic Launcher backup directory contains an unsafe entry"
        }
        $length = [Int64]$item.Length
        if (-not (Test-MajesticBackupLeafName $name) -or
            $seen.ContainsKey($name) -or
            (([int]$item.Attributes -band [int][IO.FileAttributes]::ReparsePoint) -ne 0) -or
            $length -lt 0 -or $length -gt $MaximumFileBytes) {
            throw "Majestic Launcher backup directory contains an unsafe entry"
        }
        $seen[$name] = $true
        $total += $length
        if ($total -gt $MaximumTotalBytes) {
            throw "Majestic Launcher backup directory exceeds its size limit"
        }
        $files += [pscustomobject][ordered]@{
            name = $name
            length = $length
            sha256 = Get-EgsFileSha256Hex -Path $item.FullName
            creation_time_utc_ticks = [Int64]$item.CreationTimeUtc.Ticks
            last_write_time_utc_ticks = [Int64]$item.LastWriteTimeUtc.Ticks
        }
    }
    return [pscustomobject]@{
        SourcePath = $root.FullName
        Files = @($files)
        FileCount = [int]$files.Count
        TotalBytes = $total
    }
}

function Get-PublisherMajesticBackupMetadata {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$MaximumFileCount = 64,
        [Int64]$MaximumTotalBytes = 8GB,
        [Int64]$MaximumFileBytes = 4GB
    )
    $root = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (-not $root.PSIsContainer -or
        (([int]$root.Attributes -band [int][IO.FileAttributes]::ReparsePoint) -ne 0)) {
        throw "Majestic Launcher backup payload directory is unsafe"
    }
    $children = @(Get-ChildItem -LiteralPath $root.FullName -Force | Sort-Object Name)
    if ($children.Count -lt 1 -or $children.Count -gt $MaximumFileCount) {
        throw "Majestic Launcher backup directory file count is invalid"
    }
    $files = @{}
    $total = [Int64]0
    foreach ($item in $children) {
        $name = [string]$item.Name
        $length = [Int64]$item.Length
        if ($item.PSIsContainer -or -not (Test-MajesticBackupLeafName $name) -or
            $files.ContainsKey($name) -or
            (([int]$item.Attributes -band [int][IO.FileAttributes]::ReparsePoint) -ne 0) -or
            $length -lt 0 -or $length -gt $MaximumFileBytes) {
            throw "Majestic Launcher backup directory contains an unsafe entry"
        }
        $files[$name] = $length
        $total += $length
        if ($total -gt $MaximumTotalBytes) {
            throw "Majestic Launcher backup directory exceeds its size limit"
        }
    }
    return [pscustomobject]@{
        Path = $root.FullName
        Files = $files
        FileCount = [int]$children.Count
        TotalBytes = $total
    }
}

function Assert-PublisherMajesticBackupMap {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][string]$ExpectedBackupPath,
        [Parameter(Mandatory = $true)]$BackupMetadata
    )
    try {
        $strictUtf8 = New-Object Text.UTF8Encoding($false, $true)
        $map = $strictUtf8.GetString($Bytes) | ConvertFrom-Json
    } catch {
        throw "Majestic Launcher backupMap.json is not valid UTF-8 JSON"
    }
    if ([int]$map.version -ne 1 -or
        [string]::IsNullOrWhiteSpace([string]$map.backupDir) -or
        $null -eq $map.files) {
        throw "Majestic Launcher backupMap.json metadata is invalid"
    }
    $declaredBackupPath = ConvertTo-EgsCanonicalPath ([string]$map.backupDir)
    $capturedBackupPath = ConvertTo-EgsCanonicalPath $ExpectedBackupPath
    if (-not $declaredBackupPath.Equals(
        $capturedBackupPath, [StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Majestic Launcher backupMap.json points to another backup directory"
    }
    $properties = @($map.files.PSObject.Properties)
    if ($properties.Count -lt 1 -or $properties.Count -gt $BackupMetadata.FileCount) {
        throw "Majestic Launcher backupMap.json file set is invalid"
    }
    foreach ($property in $properties) {
        $name = [string]$property.Name
        $metadata = $property.Value
        $mtime = [Int64]0
        if (-not (Test-MajesticBackupLeafName $name) -or
            -not $BackupMetadata.Files.ContainsKey($name) -or
            [Int64]$metadata.size -ne [Int64]$BackupMetadata.Files[$name] -or
            -not [Int64]::TryParse([string]$metadata.mtimeNs, [ref]$mtime) -or
            [string]$metadata.finalHash -notmatch '^[0-9A-Fa-f]{16}$') {
            throw "Majestic Launcher backupMap.json contains invalid file metadata"
        }
    }
    return $map
}

function Get-PublisherMajesticBundleBytes {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][string]$ConfigRevision
    )
    $profile = Get-Item -LiteralPath $Config.ProfilePath -Force -ErrorAction Stop
    if (-not $profile.PSIsContainer -or
        (([int]$profile.Attributes -band [int][IO.FileAttributes]::ReparsePoint) -ne 0)) {
        throw "Majestic Launcher profile path is unsafe"
    }
    $launcherRoot = Join-Path $Config.ProfilePath "AppData\Roaming\majestic-launcher"
    $prefsCapture = Get-PublisherMajesticPrefsCapture -Config $Config
    $prefsBytes = $prefsCapture.Bytes
    $majesticBytes = Get-PublisherMajesticFileBytes `
        -Path (Join-Path $launcherRoot "Multiplayer\majestic.json") `
        -Description "Multiplayer\majestic.json" -MaximumBytes 1MB -RequireJson
    $hashMapBytes = Get-PublisherMajesticFileBytes `
        -Path (Join-Path $launcherRoot "hashMap_v3_RO.json") `
        -Description "hashMap_v3_RO.json" -MaximumBytes 16MB -RequireJson
    $hashMapGeneralBytes = Get-PublisherMajesticFileBytes `
        -Path (Join-Path $launcherRoot "hashMap_v3.json") `
        -Description "hashMap_v3.json" -MaximumBytes 16MB -RequireJson
    $backupMapBytes = Get-PublisherMajesticFileBytes `
        -Path (Join-Path $launcherRoot "backupMap.json") `
        -Description "backupMap.json" -MaximumBytes 1MB -RequireJson
    $backupPath = Join-Path $launcherRoot "Multiplayer\backup"
    $backupItem = Get-Item -LiteralPath $backupPath -Force -ErrorAction Stop
    if (-not $backupItem.PSIsContainer -or
        (([int]$backupItem.Attributes -band [int][IO.FileAttributes]::ReparsePoint) -eq 0)) {
        throw "Majestic Launcher Publisher backup junction is not active"
    }
    $backupMetadata = Get-PublisherMajesticBackupMetadata `
        -Path (Get-PublisherMajesticLinkTarget -Path $backupPath)
    $backupMap = Assert-PublisherMajesticBackupMap -Bytes $backupMapBytes `
        -ExpectedBackupPath $backupPath -BackupMetadata $backupMetadata
    $safeBackupFiles = [ordered]@{}
    foreach ($property in @($backupMap.files.PSObject.Properties)) {
        $safeBackupFiles[[string]$property.Name] = [ordered]@{
            size = [Int64]$property.Value.size
            mtimeNs = [string]$property.Value.mtimeNs
            finalHash = [string]$property.Value.finalHash
        }
    }
    $registry = Get-MajesticRegistryValues -Config $Config
    Assert-MajesticLauncherStopped
    $bundle = [ordered]@{
        schema_version = 2
        config_revision = $ConfigRevision
        files = [ordered]@{
            prefs_latest_json = New-PublisherMajesticFilePayload -Bytes $prefsBytes
            multiplayer_majestic_json = New-PublisherMajesticFilePayload `
                -Bytes $majesticBytes
            hash_map_v3_ro_json = New-PublisherMajesticFilePayload -Bytes $hashMapBytes
            hash_map_v3_json = New-PublisherMajesticFilePayload -Bytes $hashMapGeneralBytes
        }
        backup_map = [ordered]@{
            version = [int]$backupMap.version
            files = $safeBackupFiles
        }
        registry = [ordered]@{
            lastVisitedServerID = [string]$registry.lastVisitedServerID
            game_disk = [string]$registry.game_disk
        }
    }
    $json = $bundle | ConvertTo-Json -Depth 8 -Compress
    return (New-Object Text.UTF8Encoding($false)).GetBytes($json)
}

function Remove-PublisherMajesticOwnedDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) { return }
    if (-not $item.PSIsContainer -or
        (([int]$item.Attributes -band [int][IO.FileAttributes]::ReparsePoint) -ne 0)) {
        throw "Majestic Launcher helper-owned backup path is unsafe"
    }
    Remove-Item -LiteralPath $Path -Recurse -Force
    if ($null -ne (Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue)) {
        throw "Majestic Launcher helper-owned backup path could not be removed"
    }
}

function Remove-PublisherMajesticLinkStage {
    param([Parameter(Mandatory = $true)][string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) { return }
    if (-not $item.PSIsContainer -or
        (([int]$item.Attributes -band [int][IO.FileAttributes]::ReparsePoint) -eq 0)) {
        throw "Majestic Launcher Publisher junction staging path is unsafe"
    }
    [IO.Directory]::Delete($item.FullName, $false)
    if ($null -ne (Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue)) {
        throw "Majestic Launcher Publisher junction staging path could not be removed"
    }
}

function New-PublisherMajesticBackupJunction {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Target
    )
    $itemType = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        "Junction"
    } else {
        "SymbolicLink"
    }
    New-Item -ItemType $itemType -Path $Path -Target $Target -ErrorAction Stop |
        Out-Null
}

function Get-PublisherMajesticLinkTarget {
    param([Parameter(Mandatory = $true)][string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (-not $item.PSIsContainer -or
        (([int]$item.Attributes -band [int][IO.FileAttributes]::ReparsePoint) -eq 0)) {
        throw "Majestic Launcher backup path is not a directory junction"
    }
    $target = [string](@($item.Target)[0])
    if ([string]::IsNullOrWhiteSpace($target)) {
        throw "Majestic Launcher backup junction target cannot be read"
    }
    if (-not [IO.Path]::IsPathRooted($target)) {
        $target = Join-Path (Split-Path $item.FullName -Parent) $target
    }
    return ConvertTo-EgsCanonicalPath $target
}

function Assert-PublisherMajesticBackupCopy {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$BackupIndex
    )
    $metadata = Get-PublisherMajesticBackupMetadata -Path $Path
    if ($metadata.FileCount -ne $BackupIndex.FileCount -or
        $metadata.TotalBytes -ne $BackupIndex.TotalBytes) {
        throw "Majestic Launcher backup copy verification failed"
    }
    foreach ($entry in @($BackupIndex.Files)) {
        $target = Join-Path $Path ([string]$entry.name)
        $item = Get-Item -LiteralPath $target -Force -ErrorAction Stop
        if ([Int64]$item.Length -ne [Int64]$entry.length -or
            (Get-EgsFileSha256Hex -Path $target) -ne [string]$entry.sha256 -or
            [Int64]$item.LastWriteTimeUtc.Ticks -ne
                [Int64]$entry.last_write_time_utc_ticks -or
            ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT -and
                [Int64]$item.CreationTimeUtc.Ticks -ne
                    [Int64]$entry.creation_time_utc_ticks)) {
            throw "Majestic Launcher backup copy verification failed"
        }
    }
    return $metadata
}

function Copy-PublisherMajesticBackupOnce {
    param(
        [Parameter(Mandatory = $true)]$BackupIndex,
        [Parameter(Mandatory = $true)][string]$Destination
    )
    New-Item -ItemType Directory -Path $Destination -ErrorAction Stop | Out-Null
    foreach ($entry in @($BackupIndex.Files)) {
        $source = Join-Path $BackupIndex.SourcePath ([string]$entry.name)
        $target = Join-Path $Destination ([string]$entry.name)
        [IO.File]::Copy($source, $target, $false)
        [IO.File]::SetLastWriteTimeUtc(
            $target, [DateTime]::new([Int64]$entry.last_write_time_utc_ticks, [DateTimeKind]::Utc)
        )
        if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
            [IO.File]::SetCreationTimeUtc(
                $target,
                [DateTime]::new([Int64]$entry.creation_time_utc_ticks, [DateTimeKind]::Utc)
            )
        }
    }
    Assert-PublisherMajesticBackupCopy -Path $Destination `
        -BackupIndex $BackupIndex | Out-Null
}

function Ensure-PublisherMajesticBackupJunction {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)]$AnchorVolume
    )
    Assert-PublisherMajesticHelperDirectory -VolumeMapping $AnchorVolume -Create
    $profileDirectory = [string]$Config.ProfilePath
    foreach ($segment in @("", "AppData", "Roaming", "majestic-launcher", "Multiplayer")) {
        if (-not [string]::IsNullOrEmpty($segment)) {
            $profileDirectory = Join-Path $profileDirectory $segment
        }
        $profileItem = Get-Item -LiteralPath $profileDirectory -Force -ErrorAction Stop
        if (-not $profileItem.PSIsContainer -or
            (([int]$profileItem.Attributes -band
                [int][IO.FileAttributes]::ReparsePoint) -ne 0)) {
            throw "Majestic Launcher Publisher profile directory is unsafe"
        }
    }
    $launcherRoot = Join-Path $Config.ProfilePath "AppData\Roaming\majestic-launcher"
    $source = Join-Path $launcherRoot "Multiplayer\backup"
    $active = Get-PublisherMajesticBackupPayloadPath -VolumeMapping $AnchorVolume
    $staging = Get-PublisherMajesticBackupPayloadPath `
        -VolumeMapping $AnchorVolume -Kind "staging"
    $previous = Get-PublisherMajesticBackupPreviousPath -BackupPath $source
    $junctionStage = Join-Path (Split-Path $source -Parent) `
        ".iscsi-reset-majestic-backup.junction.staging"
    $sourceItem = Get-Item -LiteralPath $source -Force -ErrorAction SilentlyContinue

    if ($null -ne $sourceItem -and
        (([int]$sourceItem.Attributes -band [int][IO.FileAttributes]::ReparsePoint) -ne 0)) {
        $target = Get-PublisherMajesticLinkTarget -Path $source
        $expected = ConvertTo-EgsCanonicalPath $active
        if (-not $target.Equals($expected, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Majestic Launcher Publisher backup junction points to another directory"
        }
        $metadata = Get-PublisherMajesticBackupMetadata -Path $active
        Remove-PublisherMajesticOwnedDirectory -Path $staging
        Remove-PublisherMajesticLinkStage -Path $junctionStage
        Remove-PublisherMajesticOwnedDirectory -Path $previous
        return $metadata
    }

    if ($null -eq $sourceItem) {
        $previousItem = Get-Item -LiteralPath $previous -Force -ErrorAction SilentlyContinue
        if ($null -eq $previousItem) {
            throw "Majestic Launcher Publisher backup migration state is incomplete"
        }
        if (-not $previousItem.PSIsContainer -or
            (([int]$previousItem.Attributes -band
                [int][IO.FileAttributes]::ReparsePoint) -ne 0)) {
            throw "Majestic Launcher Publisher backup recovery path is unsafe"
        }
        $sourceItem = $previousItem
    } elseif (-not $sourceItem.PSIsContainer) {
        throw "Majestic Launcher Publisher backup path is unsafe"
    } elseif (Test-Path -LiteralPath $previous) {
        throw "Majestic Launcher Publisher backup migration state is ambiguous"
    }

    $backupIndex = Get-PublisherMajesticBackupIndex -Path $sourceItem.FullName
    Remove-PublisherMajesticOwnedDirectory -Path $staging
    Remove-PublisherMajesticLinkStage -Path $junctionStage
    $activeReady = $false
    if (Test-Path -LiteralPath $active) {
        try {
            Assert-PublisherMajesticBackupCopy -Path $active `
                -BackupIndex $backupIndex | Out-Null
            $activeReady = $true
        } catch {
            Remove-PublisherMajesticOwnedDirectory -Path $active
        }
    }
    if (-not $activeReady) {
        Copy-PublisherMajesticBackupOnce -BackupIndex $backupIndex `
            -Destination $staging
        [IO.Directory]::Move($staging, $active)
        Assert-PublisherMajesticBackupCopy -Path $active `
            -BackupIndex $backupIndex | Out-Null
    }
    Assert-PublisherMajesticBackupCopy -Path $sourceItem.FullName `
        -BackupIndex $backupIndex | Out-Null

    try {
        New-PublisherMajesticBackupJunction -Path $junctionStage -Target $active
        $target = Get-PublisherMajesticLinkTarget -Path $junctionStage
        if (-not $target.Equals(
            (ConvertTo-EgsCanonicalPath $active), [StringComparison]::OrdinalIgnoreCase
        )) {
            throw "Majestic Launcher Publisher backup junction verification failed"
        }
        Get-PublisherMajesticBackupMetadata -Path $active | Out-Null
        $sourceWasPrevious = $sourceItem.FullName.Equals(
            (ConvertTo-EgsCanonicalPath $previous), [StringComparison]::OrdinalIgnoreCase
        )
        if (-not $sourceWasPrevious) {
            [IO.Directory]::Move($sourceItem.FullName, $previous)
        }
        [IO.Directory]::Move($junctionStage, $source)
        $target = Get-PublisherMajesticLinkTarget -Path $source
        if (-not $target.Equals(
            (ConvertTo-EgsCanonicalPath $active), [StringComparison]::OrdinalIgnoreCase
        )) {
            throw "Majestic Launcher Publisher backup junction verification failed"
        }
        $metadata = Get-PublisherMajesticBackupMetadata -Path $active
        Remove-PublisherMajesticOwnedDirectory -Path $previous
        return $metadata
    } catch {
        $failed = $_
        $link = Get-Item -LiteralPath $source -Force -ErrorAction SilentlyContinue
        if ($null -ne $link -and
            (([int]$link.Attributes -band [int][IO.FileAttributes]::ReparsePoint) -ne 0)) {
            [IO.Directory]::Delete($link.FullName, $false)
        }
        if (-not (Test-Path -LiteralPath $source) -and
            (Test-Path -LiteralPath $previous)) {
            [IO.Directory]::Move($previous, $source)
        }
        throw $failed
    } finally {
        Remove-PublisherMajesticOwnedDirectory -Path $staging
        Remove-PublisherMajesticLinkStage -Path $junctionStage
    }
}

function Remove-PublisherMajesticBundles {
    param([Parameter(Mandatory = $true)]$VolumeMappings)
    foreach ($mapping in $VolumeMappings) {
        Assert-PublisherMajesticHelperDirectory -VolumeMapping $mapping
        foreach ($schemaVersion in @(1, 2)) {
            $path = Get-PublisherMajesticBundlePath -VolumeMapping $mapping `
                -SchemaVersion $schemaVersion
            if (Test-Path -LiteralPath $path) {
                Remove-Item -LiteralPath $path -Force
            }
        }
    }
    foreach ($mapping in $VolumeMappings) {
        foreach ($schemaVersion in @(1, 2)) {
            if (Test-Path -LiteralPath (
                Get-PublisherMajesticBundlePath -VolumeMapping $mapping `
                    -SchemaVersion $schemaVersion
            )) {
                throw "Stale Majestic Launcher settings bundle could not be removed"
            }
        }
    }
}

function Export-PublisherMajesticBundles {
    param(
        [Parameter(Mandatory = $true)]$VolumeMappings,
        [Parameter(Mandatory = $true)][byte[]]$BundleBytes
    )
    $expectedSha = Get-EgsSha256Hex $BundleBytes
    foreach ($mapping in $VolumeMappings) {
        Assert-PublisherMajesticHelperDirectory -VolumeMapping $mapping -Create
    }
    foreach ($mapping in $VolumeMappings) {
        $v2Path = Get-PublisherMajesticBundlePath -VolumeMapping $mapping
        Remove-Item -LiteralPath $v2Path -Force -ErrorAction SilentlyContinue
    }
    foreach ($mapping in $VolumeMappings) {
        if (Test-Path -LiteralPath (
            Get-PublisherMajesticBundlePath -VolumeMapping $mapping
        )) { throw "Stale Majestic Launcher v2 marker could not be removed" }
    }
    foreach ($mapping in $VolumeMappings) {
        $path = Get-PublisherMajesticBundlePath -VolumeMapping $mapping
        Write-PublisherEgsBytesAtomic -Path $path -Bytes $BundleBytes
        $written = [IO.File]::ReadAllBytes($path)
        if ((Get-EgsSha256Hex $written) -ne $expectedSha -or
            $written.Length -ne $BundleBytes.Length) {
            throw "Majestic Launcher settings bundle verification failed"
        }
    }
    foreach ($mapping in $VolumeMappings) {
        $legacyPath = Get-PublisherMajesticBundlePath -VolumeMapping $mapping `
            -SchemaVersion 1
        if (Test-Path -LiteralPath $legacyPath) {
            Remove-Item -LiteralPath $legacyPath -Force
        }
        if (Test-Path -LiteralPath $legacyPath) {
            throw "Legacy Majestic Launcher settings bundle could not be removed"
        }
    }
    Assert-MajesticLauncherStopped
}

function Invoke-PublisherMajesticSync {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)]$VolumeMappings
    )
    if (-not $Config.Present) { return }
    if (-not $Config.Enabled) {
        Remove-PublisherMajesticBundles -VolumeMappings $VolumeMappings
        return
    }
    try {
        Stop-MajesticLauncherProcesses
    } catch {
        $stopFailure = $_
        try { Remove-PublisherMajesticBundles -VolumeMappings $VolumeMappings } catch {
            throw "Majestic Launcher stop failed and stale bundle cleanup failed"
        }
        Write-Warning "Majestic Launcher settings were not exported: $($stopFailure.Exception.Message)"
        return
    }
    $prefs = Get-PublisherMajesticPrefsCapture -Config $Config
    $anchor = Get-PublisherMajesticAnchorVolume -VolumeMappings $VolumeMappings `
        -GameDisk $prefs.GameDisk
    Ensure-PublisherMajesticBackupJunction -Config $Config `
        -AnchorVolume $anchor | Out-Null
    try {
        $bytes = Get-PublisherMajesticBundleBytes -Config $Config `
            -ConfigRevision ([string]$Manifest.config_revision)
        Export-PublisherMajesticBundles -VolumeMappings $VolumeMappings `
            -BundleBytes $bytes
    } catch {
        $captureFailure = $_
        try {
            Remove-PublisherMajesticBundles -VolumeMappings $VolumeMappings
        } catch {
            throw "Majestic Launcher settings export failed and stale bundle cleanup failed"
        }
        Write-Warning "Majestic Launcher settings were not exported: $($captureFailure.Exception.Message)"
    }
}

function Assert-PublisherEgsItem {
    param(
        [Parameter(Mandatory = $true)]$Item,
        [Parameter(Mandatory = $true)][string]$ItemPath,
        [Parameter(Mandatory = $true)]$VolumeMapping
    )
    $appName = Get-RequiredEgsString -Item $Item -Name "AppName"
    $guid = Get-RequiredEgsString -Item $Item -Name "InstallationGuid"
    if (-not (Test-EgsInstallationId $guid)) {
        throw "$appName has an invalid Epic installation identifier"
    }
    if (-not ([IO.Path]::GetFileName($ItemPath)).Equals(
        "$guid.item", [StringComparison]::OrdinalIgnoreCase
    )) {
        throw "$appName .item filename does not match InstallationGuid"
    }
    $appVersion = Get-RequiredEgsString -Item $Item -Name "AppVersionString"
    if ($Item.PSObject.Properties.Name -notcontains "InstallTags") {
        throw "$appName manifest has no InstallTags"
    }

    $installLocation = ConvertTo-EgsCanonicalPath (
        Get-RequiredEgsString -Item $Item -Name "InstallLocation"
    )
    if (-not (Test-EgsPathWithinRoot -Path $installLocation -RootPath $VolumeMapping.RootPath)) {
        throw "$appName is outside Publisher volume $($VolumeMapping.Name)"
    }
    if (-not (Test-Path -LiteralPath $installLocation -PathType Container)) {
        throw "$appName install directory does not exist"
    }
    $egstore = ConvertTo-EgsCanonicalPath (Join-Path $installLocation ".egstore")
    $manifestLocation = ConvertTo-EgsCanonicalPath (
        Get-RequiredEgsString -Item $Item -Name "ManifestLocation"
    )
    if (-not $manifestLocation.Equals($egstore, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$appName ManifestLocation does not match its .egstore directory"
    }
    $stagingLocation = ConvertTo-EgsCanonicalPath (
        Get-RequiredEgsString -Item $Item -Name "StagingLocation"
    )
    $expectedStaging = ConvertTo-EgsCanonicalPath (Join-Path $egstore "bps")
    if (-not $stagingLocation.Equals($expectedStaging, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$appName StagingLocation does not match its .egstore directory"
    }

    $binaryManifest = Join-Path $egstore "$guid.manifest"
    $component = Join-Path $egstore "$guid.mancpn"
    if (-not (Test-Path -LiteralPath $binaryManifest -PathType Leaf)) {
        throw "$appName .egstore binary manifest is missing"
    }
    if ((Get-Item -LiteralPath $binaryManifest).Length -le 0) {
        throw "$appName binary manifest is empty"
    }
    $componentSha256 = $null
    if (Test-Path -LiteralPath $component -PathType Leaf) {
        $componentData = Get-Content -LiteralPath $component -Raw | ConvertFrom-Json
        if ([string]$componentData.AppName -ne $appName) {
            throw "$appName .mancpn AppName does not match"
        }
        $componentSha256 = Get-EgsSha256Hex ([IO.File]::ReadAllBytes($component))
    }

    if ($Item.PSObject.Properties.Name -contains "LaunchExecutable" -and
        -not [string]::IsNullOrWhiteSpace([string]$Item.LaunchExecutable)) {
        $launchPath = [string]$Item.LaunchExecutable
        if (-not [IO.Path]::IsPathRooted($launchPath)) {
            $launchPath = Join-Path $installLocation $launchPath
        }
        if (-not (Test-Path -LiteralPath $launchPath -PathType Leaf)) {
            throw "$appName launch executable does not exist"
        }
    }
    $warnings = @(Get-PublisherEgsStateWarnings -Item $Item `
        -InstallLocation $installLocation)
    foreach ($warning in $warnings) {
        Write-Warning "$appName Epic installation state: $warning"
    }
    return [pscustomobject]@{
        AppName = $appName
        AppVersion = $appVersion
        InstallationGuid = $guid
        InstallLocation = $installLocation
        BinaryManifestSha256 = Get-EgsSha256Hex ([IO.File]::ReadAllBytes($binaryManifest))
        MancpnSha256 = $componentSha256
        StateWarnings = $warnings
    }
}

function Read-PublisherEgsLauncherInstallationList {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Write-Warning "Epic Games LauncherInstalled.dat is missing; using item-only fallback"
        return @()
    }
    try {
        $bytes = [IO.File]::ReadAllBytes($Path)
        $launcher = ConvertFrom-EgsJsonBytes -Bytes $bytes
        if ($launcher.PSObject.Properties.Name -notcontains "InstallationList") {
            throw "InstallationList is missing"
        }
        return @($launcher.InstallationList)
    } catch {
        Write-Warning "Epic Games LauncherInstalled.dat is unusable; using item-only fallback"
        return @()
    }
}

function Get-PublisherEgsLauncherRegistration {
    param(
        [Parameter(Mandatory = $true)]$InstallationList,
        [Parameter(Mandatory = $true)]$Identity
    )
    $matches = @($InstallationList | Where-Object {
        $null -ne $_ -and $_.PSObject.Properties.Name -contains "AppName" -and
        [string]$_.AppName -eq [string]$Identity.AppName
    })
    if ($matches.Count -ne 1) {
        Write-Warning "$($Identity.AppName) has no unique LauncherInstalled.dat registration; using item-only fallback"
        return $null
    }
    $entry = $matches[0]
    $required = @(
        "InstallLocation", "NamespaceId", "ItemId", "ArtifactId", "AppVersion", "AppName"
    )
    foreach ($name in $required) {
        if ($entry.PSObject.Properties.Name -notcontains $name -or
            [string]::IsNullOrWhiteSpace([string]$entry.$name)) {
            Write-Warning "$($Identity.AppName) has an incomplete LauncherInstalled.dat registration; using item-only fallback"
            return $null
        }
    }
    try {
        $location = ConvertTo-EgsCanonicalPath ([string]$entry.InstallLocation)
    } catch {
        Write-Warning "$($Identity.AppName) has an invalid LauncherInstalled.dat path; using item-only fallback"
        return $null
    }
    if (-not $location.Equals(
        [string]$Identity.InstallLocation,
        [StringComparison]::OrdinalIgnoreCase
    ) -or -not [string]::Equals(
        [string]$entry.AppVersion,
        [string]$Identity.AppVersion,
        [StringComparison]::Ordinal
    )) {
        Write-Warning "$($Identity.AppName) LauncherInstalled.dat path or version differs; using item-only fallback"
        return $null
    }
    return [ordered]@{
        install_location = $location
        namespace_id = [string]$entry.NamespaceId
        item_id = [string]$entry.ItemId
        artifact_id = [string]$entry.ArtifactId
        app_version = [string]$entry.AppVersion
        app_name = [string]$entry.AppName
    }
}

function Assert-PublisherEgsBundle {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ConfigRevision,
        [Parameter(Mandatory = $true)][string]$VolumeName,
        [Parameter(Mandatory = $true)][string]$VolumeRoot
    )
    $bundle = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ([int]$bundle.schema_version -ne 2 -or
        [string]$bundle.config_revision -ne $ConfigRevision -or
        [string]$bundle.volume_name -ne $VolumeName -or
        $bundle.PSObject.Properties.Name -notcontains "manifests") {
        throw "Epic Games bundle verification failed for volume $VolumeName"
    }
    foreach ($entry in @($bundle.manifests)) {
        $bytes = [Convert]::FromBase64String([string]$entry.payload_base64)
        if ((Get-EgsSha256Hex $bytes) -ne [string]$entry.sha256) {
            throw "Epic Games bundle hash verification failed for $($entry.app_name)"
        }
        $item = ConvertFrom-EgsJsonBytes -Bytes $bytes
        if ([string]$item.AppName -ne [string]$entry.app_name -or
            [string]$item.InstallationGuid -ne [string]$entry.installation_guid) {
            throw "Epic Games bundle identity verification failed"
        }
        $installLocation = ConvertTo-EgsCanonicalPath ([string]$item.InstallLocation)
        if (-not (Test-EgsPathWithinRoot -Path $installLocation -RootPath $VolumeRoot)) {
            throw "Epic Games bundle path verification failed for $($entry.app_name)"
        }
        $egstore = Join-Path $installLocation ".egstore"
        $binaryManifest = Join-Path $egstore "$($entry.installation_guid).manifest"
        if (-not (Test-Path -LiteralPath $binaryManifest -PathType Leaf) -or
            (Get-EgsSha256Hex ([IO.File]::ReadAllBytes($binaryManifest))) -ne
                [string]$entry.binary_manifest_sha256) {
            throw "Epic Games binary manifest hash verification failed for $($entry.app_name)"
        }
        $component = Join-Path $egstore "$($entry.installation_guid).mancpn"
        $componentExists = Test-Path -LiteralPath $component -PathType Leaf
        $expectedComponentSha = [string]$entry.mancpn_sha256
        if ($componentExists -ne (-not [string]::IsNullOrWhiteSpace($expectedComponentSha))) {
            throw "Epic Games component presence verification failed for $($entry.app_name)"
        }
        if ($componentExists -and
            (Get-EgsSha256Hex ([IO.File]::ReadAllBytes($component))) -ne
                $expectedComponentSha) {
            throw "Epic Games component hash verification failed for $($entry.app_name)"
        }
        $warnings = @(Get-PublisherEgsStateWarnings -Item $item `
            -InstallLocation $installLocation)
        $actualWarningKey = (@($warnings) | Sort-Object) -join ","
        $bundleWarningKey = (@($entry.state_warnings) | Sort-Object) -join ","
        if ($actualWarningKey -cne $bundleWarningKey) {
            throw "Epic Games state warning verification failed for $($entry.app_name)"
        }
        if ($null -ne $entry.launcher_registration) {
            $registration = $entry.launcher_registration
            $registrationNames = @($registration.PSObject.Properties.Name | Sort-Object)
            $requiredRegistrationNames = @(
                "install_location", "namespace_id", "item_id", "artifact_id", "app_version",
                "app_name"
            ) | Sort-Object
            if (($registrationNames -join ",") -cne
                ($requiredRegistrationNames -join ",")) {
                throw "Epic Games launcher registration fields are unsafe for $($entry.app_name)"
            }
            $registrationLocation = ConvertTo-EgsCanonicalPath (
                [string]$registration.install_location
            )
            if ([string]$registration.app_name -ne [string]$entry.app_name -or
                -not $registrationLocation.Equals(
                    $installLocation, [StringComparison]::OrdinalIgnoreCase
                ) -or
                [string]$registration.app_version -ne [string]$item.AppVersionString) {
                throw "Epic Games launcher registration verification failed for $($entry.app_name)"
            }
            foreach ($name in @("namespace_id", "item_id", "artifact_id")) {
                if ([string]::IsNullOrWhiteSpace([string]$registration.$name)) {
                    throw "Epic Games launcher registration verification failed for $($entry.app_name)"
                }
            }
        }
    }
}

function Write-PublisherEgsBundleAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Bundle
    )
    $directory = Split-Path $Path -Parent
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $temporary = Join-Path $directory (".egs-bundle-" + [Guid]::NewGuid().ToString("N") + ".tmp")
    $backup = Join-Path $directory (".egs-bundle-" + [Guid]::NewGuid().ToString("N") + ".bak")
    try {
        $json = $Bundle | ConvertTo-Json -Depth 8
        [IO.File]::WriteAllText($temporary, $json, (New-Object Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $Path) {
            [IO.File]::Replace($temporary, $Path, $backup)
            Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
        } else {
            [IO.File]::Move($temporary, $Path)
        }
    } finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    }
}

function Remove-PublisherEgsLegacyBundle {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Force
    }
}

function Initialize-EgsZipSupport {
    try { Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop } catch { }
    try { Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop } catch { }
}

function Write-PublisherEgsBytesAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][byte[]]$Bytes
    )
    $directory = Split-Path $Path -Parent
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $temporary = Join-Path $directory (".egs-state-" + [Guid]::NewGuid().ToString("N") + ".tmp")
    $backup = Join-Path $directory (".egs-state-" + [Guid]::NewGuid().ToString("N") + ".bak")
    try {
        [IO.File]::WriteAllBytes($temporary, $Bytes)
        if (Test-Path -LiteralPath $Path) {
            [IO.File]::Replace($temporary, $Path, $backup)
            Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
        } else {
            [IO.File]::Move($temporary, $Path)
        }
    } finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    }
}

function Test-EgsReparsePoint {
    param([Parameter(Mandatory = $true)]$Item)
    return ([int]$Item.Attributes -band [int][IO.FileAttributes]::ReparsePoint) -ne 0
}

function ConvertTo-EgsArchiveRelativePath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $candidate = $Path.Replace("\", "/")
    if ([string]::IsNullOrWhiteSpace($candidate) -or
        $candidate.StartsWith("/") -or $candidate.EndsWith("/") -or
        $candidate.Contains(":") -or $candidate.Contains("//")) {
        throw "Epic Games aggressive state contains an unsafe relative path"
    }
    foreach ($segment in @($candidate -split "/")) {
        if ([string]::IsNullOrWhiteSpace($segment) -or $segment -in @(".", "..")) {
            throw "Epic Games aggressive state contains an unsafe relative path"
        }
    }
    return $candidate
}

function Get-PublisherEgsAggressiveIndexData {
    param(
        [Parameter(Mandatory = $true)][string]$ProgramDataPath,
        [Parameter(Mandatory = $true)][string]$LauncherInstalledPath,
        [Parameter(Mandatory = $true)][string]$SharedInstallDbPath,
        [int]$MaximumFileCount = 100000,
        [Int64]$MaximumTotalBytes = 1GB,
        [Int64]$MaximumFileBytes = 512MB
    )
    foreach ($root in @($ProgramDataPath, $LauncherInstalledPath, $SharedInstallDbPath)) {
        if (-not (Test-Path -LiteralPath $root)) {
            throw "Epic Games aggressive state source is missing: $root"
        }
        if (Test-EgsReparsePoint (Get-Item -LiteralPath $root -Force)) {
            throw "Epic Games aggressive state source is a reparse point"
        }
    }
    if (-not (Test-Path -LiteralPath $ProgramDataPath -PathType Container) -or
        -not (Test-Path -LiteralPath $LauncherInstalledPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $SharedInstallDbPath -PathType Container)) {
        throw "Epic Games aggressive state sources have invalid types"
    }

    $sourceRoot = (Get-Item -LiteralPath $ProgramDataPath -Force).FullName.TrimEnd(
        [char[]]@(92, 47)
    )
    $sharedSourceRoot = (Get-Item -LiteralPath $SharedInstallDbPath -Force).FullName.TrimEnd(
        [char[]]@(92, 47)
    )
    $sharedInstallHelperPath = Split-Path $SharedInstallDbPath -Parent
    $sharedRootPath = Split-Path $sharedInstallHelperPath -Parent
    $seen = @{}
    $directories = @()
    $files = @()
    $totalBytes = [Int64]0

    $fixedDirectories = @(
        [pscustomobject]@{
            ArchivePath = "EpicGamesLauncher"
            SourcePath = Split-Path $ProgramDataPath -Parent
        },
        [pscustomobject]@{
            ArchivePath = "EpicGamesLauncher/Data"
            SourcePath = $ProgramDataPath
        },
        [pscustomobject]@{
            ArchivePath = "UnrealEngineLauncher"
            SourcePath = Split-Path $LauncherInstalledPath -Parent
        },
        [pscustomobject]@{
            ArchivePath = "EpicOnlineServicesShared"
            SourcePath = $sharedRootPath
        },
        [pscustomobject]@{
            ArchivePath = "EpicOnlineServicesShared/InstallHelper"
            SourcePath = $sharedInstallHelperPath
        },
        [pscustomobject]@{
            ArchivePath = "EpicOnlineServicesShared/InstallHelper/InstalledItems"
            SourcePath = $SharedInstallDbPath
        }
    )
    foreach ($fixedDirectory in $fixedDirectories) {
        $sourceDirectory = Get-Item -LiteralPath $fixedDirectory.SourcePath -Force
        if (-not $sourceDirectory.PSIsContainer -or
            (Test-EgsReparsePoint $sourceDirectory)) {
            throw "Epic Games aggressive state contains an invalid root directory"
        }
        $seen[$fixedDirectory.ArchivePath] = $true
        $directories += [pscustomobject]@{
            ArchivePath = $fixedDirectory.ArchivePath
            Attributes = [int]$sourceDirectory.Attributes
            CreationTimeUtc = $sourceDirectory.CreationTimeUtc.ToString("o")
            LastWriteTimeUtc = $sourceDirectory.LastWriteTimeUtc.ToString("o")
        }
    }

    $sharedFileCount = 0
    $sharedTotalBytes = [Int64]0
    foreach ($item in @(Get-ChildItem -LiteralPath $SharedInstallDbPath -Recurse -Force)) {
        if (Test-EgsReparsePoint $item) {
            throw "Epic Games aggressive state contains a reparse point"
        }
        $relative = $item.FullName.Substring($sharedSourceRoot.Length).TrimStart(
            [char[]]@(92, 47)
        )
        $archivePath = ConvertTo-EgsArchiveRelativePath (
            "EpicOnlineServicesShared/InstallHelper/InstalledItems/" +
                $relative.Replace("\", "/")
        )
        if ($seen.ContainsKey($archivePath)) {
            throw "Epic Games aggressive state contains a duplicate relative path"
        }
        $seen[$archivePath] = $true
        if ($item.PSIsContainer) {
            $directories += [pscustomobject]@{
                ArchivePath = $archivePath
                Attributes = [int]$item.Attributes
                CreationTimeUtc = $item.CreationTimeUtc.ToString("o")
                LastWriteTimeUtc = $item.LastWriteTimeUtc.ToString("o")
            }
            continue
        }
        if ([Int64]$item.Length -gt $MaximumFileBytes) {
            throw "Epic Games aggressive state contains a file larger than the safety limit"
        }
        $sharedFileCount++
        $sharedTotalBytes += [Int64]$item.Length
        $totalBytes += [Int64]$item.Length
        if ($totalBytes -gt $MaximumTotalBytes) {
            throw "Epic Games aggressive state exceeds the total size safety limit"
        }
        $files += [pscustomobject]@{
            ArchivePath = $archivePath
            SourcePath = $item.FullName
            Length = [Int64]$item.Length
            Sha256 = Get-EgsFileSha256Hex -Path $item.FullName
            Attributes = [int]$item.Attributes
            CreationTimeUtc = $item.CreationTimeUtc.ToString("o")
            LastWriteTimeUtc = $item.LastWriteTimeUtc.ToString("o")
        }
    }
    if ($sharedFileCount -eq 0) {
        throw "Epic Games shared installation database is empty"
    }

    foreach ($item in @(Get-ChildItem -LiteralPath $ProgramDataPath -Recurse -Force)) {
        if (Test-EgsReparsePoint $item) {
            throw "Epic Games aggressive state contains a reparse point"
        }
        $relative = $item.FullName.Substring($sourceRoot.Length).TrimStart(
            [char[]]@(92, 47)
        )
        $archivePath = ConvertTo-EgsArchiveRelativePath (
            "EpicGamesLauncher/Data/" + $relative.Replace("\", "/")
        )
        if ($seen.ContainsKey($archivePath)) {
            throw "Epic Games aggressive state contains a duplicate relative path"
        }
        $seen[$archivePath] = $true
        if ($item.PSIsContainer) {
            $directories += [pscustomobject]@{
                ArchivePath = $archivePath
                Attributes = [int]$item.Attributes
                CreationTimeUtc = $item.CreationTimeUtc.ToString("o")
                LastWriteTimeUtc = $item.LastWriteTimeUtc.ToString("o")
            }
            continue
        }
        if ([Int64]$item.Length -gt $MaximumFileBytes) {
            throw "Epic Games aggressive state contains a file larger than the safety limit"
        }
        $totalBytes += [Int64]$item.Length
        if ($totalBytes -gt $MaximumTotalBytes) {
            throw "Epic Games aggressive state exceeds the total size safety limit"
        }
        $files += [pscustomobject]@{
            ArchivePath = $archivePath
            SourcePath = $item.FullName
            Length = [Int64]$item.Length
            Sha256 = Get-EgsFileSha256Hex -Path $item.FullName
            Attributes = [int]$item.Attributes
            CreationTimeUtc = $item.CreationTimeUtc.ToString("o")
            LastWriteTimeUtc = $item.LastWriteTimeUtc.ToString("o")
        }
    }

    $launcherItem = Get-Item -LiteralPath $LauncherInstalledPath -Force
    $launcherArchivePath = "UnrealEngineLauncher/LauncherInstalled.dat"
    if ([Int64]$launcherItem.Length -gt $MaximumFileBytes) {
        throw "Epic Games LauncherInstalled.dat exceeds the file size safety limit"
    }
    $totalBytes += [Int64]$launcherItem.Length
    if ($totalBytes -gt $MaximumTotalBytes) {
        throw "Epic Games aggressive state exceeds the total size safety limit"
    }
    $files += [pscustomobject]@{
        ArchivePath = $launcherArchivePath
        SourcePath = $launcherItem.FullName
        Length = [Int64]$launcherItem.Length
        Sha256 = Get-EgsFileSha256Hex -Path $launcherItem.FullName
        Attributes = [int]$launcherItem.Attributes
        CreationTimeUtc = $launcherItem.CreationTimeUtc.ToString("o")
        LastWriteTimeUtc = $launcherItem.LastWriteTimeUtc.ToString("o")
    }
    if ($files.Count -gt $MaximumFileCount) {
        throw "Epic Games aggressive state exceeds the file count safety limit"
    }

    $publicDirectories = @($directories | Sort-Object ArchivePath | ForEach-Object {
        [ordered]@{
            relative_path = $_.ArchivePath
            attributes = [int]$_.Attributes
            creation_time_utc = [string]$_.CreationTimeUtc
            last_write_time_utc = [string]$_.LastWriteTimeUtc
        }
    })
    $publicFiles = @($files | Sort-Object ArchivePath | ForEach-Object {
        [ordered]@{
            relative_path = $_.ArchivePath
            length = [Int64]$_.Length
            sha256 = [string]$_.Sha256
            attributes = [int]$_.Attributes
            creation_time_utc = [string]$_.CreationTimeUtc
            last_write_time_utc = [string]$_.LastWriteTimeUtc
        }
    })
    return [pscustomobject]@{
        Directories = @($directories | Sort-Object ArchivePath)
        Files = @($files | Sort-Object ArchivePath)
        TotalBytes = $totalBytes
        SharedInstallDbFileCount = $sharedFileCount
        SharedInstallDbTotalBytes = $sharedTotalBytes
        PublicIndex = [ordered]@{
            schema_version = 2
            file_count = $files.Count
            total_bytes = $totalBytes
            directories = $publicDirectories
            files = $publicFiles
        }
    }
}

function ConvertTo-PublisherEgsIndexBytes {
    param([Parameter(Mandatory = $true)]$Index)
    $json = $Index | ConvertTo-Json -Depth 8
    return (New-Object Text.UTF8Encoding($false)).GetBytes($json)
}

function Write-PublisherEgsAggressiveArchiveAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$IndexData
    )
    Initialize-EgsZipSupport
    $directory = Split-Path $Path -Parent
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $temporary = Join-Path $directory (".egs-programdata-" + [Guid]::NewGuid().ToString("N") + ".tmp")
    $backup = Join-Path $directory (".egs-programdata-" + [Guid]::NewGuid().ToString("N") + ".bak")
    try {
        $fileStream = New-Object IO.FileStream(
            $temporary,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::None
        )
        $archive = New-Object IO.Compression.ZipArchive(
            $fileStream,
            [IO.Compression.ZipArchiveMode]::Create,
            $false
        )
        try {
            foreach ($entry in $IndexData.Directories) {
                $archive.CreateEntry("$($entry.ArchivePath)/") | Out-Null
            }
            foreach ($source in $IndexData.Files) {
                $zipEntry = $archive.CreateEntry(
                    [string]$source.ArchivePath,
                    [IO.Compression.CompressionLevel]::Optimal
                )
                $input = [IO.File]::OpenRead([string]$source.SourcePath)
                $output = $zipEntry.Open()
                try { $input.CopyTo($output) } finally {
                    $output.Dispose()
                    $input.Dispose()
                }
            }
        } finally {
            $archive.Dispose()
            $fileStream.Dispose()
        }
        if (Test-Path -LiteralPath $Path) {
            [IO.File]::Replace($temporary, $Path, $backup)
            Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
        } else {
            [IO.File]::Move($temporary, $Path)
        }
    } finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    }
}

function Assert-PublisherEgsAggressivePayload {
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$IndexPath,
        [Parameter(Mandatory = $true)]$IndexData
    )
    Initialize-EgsZipSupport
    $indexBytes = [IO.File]::ReadAllBytes($IndexPath)
    $expectedIndexBytes = ConvertTo-PublisherEgsIndexBytes -Index $IndexData.PublicIndex
    if ((Get-EgsSha256Hex $indexBytes) -ne (Get-EgsSha256Hex $expectedIndexBytes)) {
        throw "Epic Games aggressive index bytes verification failed"
    }
    $parsed = ConvertFrom-EgsJsonBytes -Bytes $indexBytes
    if ([int]$parsed.schema_version -ne 2 -or
        [int]$parsed.file_count -ne @($IndexData.Files).Count -or
        [Int64]$parsed.total_bytes -ne [Int64]$IndexData.TotalBytes) {
        throw "Epic Games aggressive index verification failed"
    }
    $zip = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        $zipFiles = @($zip.Entries | Where-Object { -not $_.FullName.EndsWith("/") })
        $zipDirectories = @($zip.Entries | Where-Object { $_.FullName.EndsWith("/") })
        if ($zipFiles.Count -ne @($IndexData.Files).Count) {
            throw "Epic Games aggressive archive file count verification failed"
        }
        if ($zipDirectories.Count -ne @($IndexData.Directories).Count) {
            throw "Epic Games aggressive archive directory count verification failed"
        }
        foreach ($directory in $IndexData.Directories) {
            if (@($zipDirectories | Where-Object {
                $_.FullName -ceq "$($directory.ArchivePath)/"
            }).Count -ne 1) {
                throw "Epic Games aggressive archive directory verification failed"
            }
        }
        foreach ($source in $IndexData.Files) {
            if ((Get-EgsFileSha256Hex -Path ([string]$source.SourcePath)) -ne
                [string]$source.Sha256) {
                throw "Epic Games aggressive source changed during export"
            }
            $matches = @($zipFiles | Where-Object {
                $_.FullName -ceq [string]$source.ArchivePath
            })
            if ($matches.Count -ne 1 -or [Int64]$matches[0].Length -ne [Int64]$source.Length) {
                throw "Epic Games aggressive archive entry verification failed"
            }
            $stream = $matches[0].Open()
            $algorithm = [Security.Cryptography.SHA256]::Create()
            try {
                $sha = (($algorithm.ComputeHash($stream) | ForEach-Object {
                    $_.ToString("x2")
                }) -join "")
            } finally {
                $algorithm.Dispose()
                $stream.Dispose()
            }
            if ($sha -ne [string]$source.Sha256) {
                throw "Epic Games aggressive archive hash verification failed"
            }
        }
    } finally {
        $zip.Dispose()
    }
}

function Export-PublisherEgsBundles {
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)]$VolumeMappings,
        [Parameter(Mandatory = $true)][string]$ManifestDirectory,
        [string]$LauncherInstalledPath =
            "C:\ProgramData\Epic\UnrealEngineLauncher\LauncherInstalled.dat",
        [switch]$PreserveLegacyBundles
    )
    if (-not (Test-Path -LiteralPath $ManifestDirectory -PathType Container)) {
        throw "Epic Games manifest directory does not exist: $ManifestDirectory"
    }
    Assert-EgsLauncherStopped
    $byVolume = @{}
    foreach ($mapping in $VolumeMappings) { $byVolume[$mapping.Name] = @() }
    $seenApps = @{}

    foreach ($file in @(Get-ChildItem -LiteralPath $ManifestDirectory -Filter "*.item" -File | Sort-Object Name)) {
        $bytes = [IO.File]::ReadAllBytes($file.FullName)
        try {
            $item = ConvertFrom-EgsJsonBytes -Bytes $bytes
        } catch {
            throw "Epic Games manifest is not valid JSON: $($file.FullName)"
        }
        $installLocation = ConvertTo-EgsCanonicalPath (
            Get-RequiredEgsString -Item $item -Name "InstallLocation"
        )
        $mapping = @($VolumeMappings | Where-Object {
            Test-EgsPathWithinRoot -Path $installLocation -RootPath $_.RootPath
        })
        if ($mapping.Count -eq 0) { continue }
        if ($mapping.Count -ne 1) {
            throw "Epic Games manifest maps to more than one Publisher volume"
        }
        $identity = Assert-PublisherEgsItem -Item $item -ItemPath $file.FullName `
            -VolumeMapping $mapping[0]
        $appName = [string]$item.AppName
        if ($seenApps.ContainsKey($appName)) {
            throw "Duplicate Epic Games AppName on Publisher volumes: $appName"
        }
        $seenApps[$appName] = $true
        $entry = [ordered]@{
            app_name = $appName
            installation_guid = [string]$item.InstallationGuid
            sha256 = Get-EgsSha256Hex $bytes
            payload_base64 = [Convert]::ToBase64String($bytes)
            binary_manifest_sha256 = [string]$identity.BinaryManifestSha256
            mancpn_sha256 = $identity.MancpnSha256
            launcher_registration = $null
            state_warnings = @($identity.StateWarnings)
            _identity = $identity
        }
        $byVolume[$mapping[0].Name] = @($byVolume[$mapping[0].Name]) + $entry
    }

    $launcherEntries = @()
    if ($seenApps.Count -gt 0) {
        $launcherEntries = @(Read-PublisherEgsLauncherInstallationList `
            -Path $LauncherInstalledPath)
    }
    foreach ($mapping in $VolumeMappings) {
        foreach ($entry in @($byVolume[$mapping.Name])) {
            $entry.launcher_registration = Get-PublisherEgsLauncherRegistration `
                -InstallationList $launcherEntries -Identity $entry._identity
            $entry.Remove("_identity")
        }
    }

    foreach ($mapping in $VolumeMappings) {
        $bundlePath = Join-Path $mapping.RootPath ".iscsi-reset\egs-manifests.v2.json"
        $bundle = [ordered]@{
            schema_version = 2
            config_revision = [string]$Manifest.config_revision
            volume_name = [string]$mapping.Name
            manifests = @($byVolume[$mapping.Name] | Sort-Object app_name)
        }
        Write-PublisherEgsBundleAtomic -Path $bundlePath -Bundle $bundle
    }
    foreach ($mapping in $VolumeMappings) {
        $bundlePath = Join-Path $mapping.RootPath ".iscsi-reset\egs-manifests.v2.json"
        Assert-PublisherEgsBundle -Path $bundlePath `
            -ConfigRevision ([string]$Manifest.config_revision) -VolumeName $mapping.Name `
            -VolumeRoot $mapping.RootPath
    }
    if (-not $PreserveLegacyBundles) {
        foreach ($mapping in $VolumeMappings) {
            $legacyPath = Join-Path $mapping.RootPath ".iscsi-reset\egs-manifests.v1.json"
            Remove-PublisherEgsLegacyBundle -Path $legacyPath
        }
        foreach ($mapping in $VolumeMappings) {
            $legacyPath = Join-Path $mapping.RootPath ".iscsi-reset\egs-manifests.v1.json"
            if (Test-Path -LiteralPath $legacyPath) {
                throw "Legacy Epic Games bundle removal failed for volume $($mapping.Name)"
            }
        }
    }
    Assert-EgsLauncherStopped
}

function Assert-PublisherEgsV4Bundle {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ConfigRevision,
        [Parameter(Mandatory = $true)][string]$VolumeName,
        [Parameter(Mandatory = $true)]$PublisherVolumeNames,
        [Parameter(Mandatory = $true)]$ArchiveMetadata
    )
    $bundle = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ([int]$bundle.schema_version -ne 4 -or
        [string]$bundle.config_revision -ne $ConfigRevision -or
        [string]$bundle.volume_name -ne $VolumeName -or
        $bundle.PSObject.Properties.Name -notcontains "manifests") {
        throw "Epic Games aggressive bundle verification failed for volume $VolumeName"
    }
    if ((@($bundle.publisher_volume_names) -join "`n") -cne
        (@($PublisherVolumeNames) -join "`n")) {
        throw "Epic Games aggressive volume set verification failed"
    }
    foreach ($name in @(
        "anchor_volume", "archive_file_name", "archive_sha256", "archive_length",
        "index_file_name", "index_sha256", "index_length", "tree_sha256",
        "file_count", "total_bytes"
    )) {
        if ($bundle.archive.PSObject.Properties.Name -notcontains $name -or
            [string]$bundle.archive.$name -cne [string]$ArchiveMetadata[$name]) {
            throw "Epic Games aggressive archive metadata verification failed"
        }
    }
    $seen = @{}
    foreach ($entry in @($bundle.manifests)) {
        $appName = [string]$entry.app_name
        if ([string]::IsNullOrWhiteSpace($appName) -or $seen.ContainsKey($appName) -or
            [string]$entry.sha256 -notmatch "^[0-9A-Fa-f]{64}$") {
            throw "Epic Games aggressive inventory verification failed"
        }
        $seen[$appName] = $true
    }
}

function Export-PublisherEgsAggressiveBundles {
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)]$VolumeMappings,
        [Parameter(Mandatory = $true)][string]$ManifestDirectory,
        [Parameter(Mandatory = $true)][string]$ProgramDataPath,
        [Parameter(Mandatory = $true)][string]$LauncherInstalledPath,
        [Parameter(Mandatory = $true)][string]$SharedInstallDbPath
    )
    if (@($VolumeMappings).Count -eq 0) {
        throw "Epic Games aggressive export requires Publisher volumes"
    }
    Assert-EgsLauncherStopped
    Wait-EgsSharedInstallDbIdle -InstallDbPath $SharedInstallDbPath
    Export-PublisherEgsBundles -Manifest $Manifest -VolumeMappings $VolumeMappings `
        -ManifestDirectory $ManifestDirectory -LauncherInstalledPath $LauncherInstalledPath `
        -PreserveLegacyBundles

    $anchor = $VolumeMappings[0]
    $metadataDirectory = Join-Path $anchor.RootPath ".iscsi-reset"
    $archivePath = Join-Path $metadataDirectory "egs-state.v4.zip"
    $indexPath = Join-Path $metadataDirectory "egs-state.v4.index.json"
    $indexData = Get-PublisherEgsAggressiveIndexData -ProgramDataPath $ProgramDataPath `
        -LauncherInstalledPath $LauncherInstalledPath `
        -SharedInstallDbPath $SharedInstallDbPath
    $indexBytes = ConvertTo-PublisherEgsIndexBytes -Index $indexData.PublicIndex
    Write-PublisherEgsAggressiveArchiveAtomic -Path $archivePath -IndexData $indexData
    Write-PublisherEgsBytesAtomic -Path $indexPath -Bytes $indexBytes
    Assert-PublisherEgsAggressivePayload -ArchivePath $archivePath -IndexPath $indexPath `
        -IndexData $indexData

    $archiveMetadata = [ordered]@{
        anchor_volume = [string]$anchor.Name
        archive_file_name = "egs-state.v4.zip"
        archive_sha256 = Get-EgsFileSha256Hex -Path $archivePath
        archive_length = [Int64](Get-Item -LiteralPath $archivePath).Length
        index_file_name = "egs-state.v4.index.json"
        index_sha256 = Get-EgsSha256Hex $indexBytes
        index_length = [Int64]$indexBytes.Length
        tree_sha256 = Get-EgsSha256Hex $indexBytes
        file_count = @($indexData.Files).Count
        total_bytes = [Int64]$indexData.TotalBytes
    }
    $publisherVolumeNames = @($VolumeMappings | ForEach-Object { [string]$_.Name })

    foreach ($mapping in $VolumeMappings) {
        $v2Path = Join-Path $mapping.RootPath ".iscsi-reset\egs-manifests.v2.json"
        $v2 = Get-Content -LiteralPath $v2Path -Raw | ConvertFrom-Json
        $v4 = [ordered]@{
            schema_version = 4
            config_revision = [string]$Manifest.config_revision
            volume_name = [string]$mapping.Name
            publisher_volume_names = $publisherVolumeNames
            archive = $archiveMetadata
            manifests = @($v2.manifests)
        }
        Write-PublisherEgsBundleAtomic `
            -Path (Join-Path $mapping.RootPath ".iscsi-reset\egs-manifests.v4.json") `
            -Bundle $v4
    }
    foreach ($mapping in $VolumeMappings) {
        Assert-PublisherEgsV4Bundle `
            -Path (Join-Path $mapping.RootPath ".iscsi-reset\egs-manifests.v4.json") `
            -ConfigRevision ([string]$Manifest.config_revision) `
            -VolumeName ([string]$mapping.Name) `
            -PublisherVolumeNames $publisherVolumeNames -ArchiveMetadata $archiveMetadata
    }

    foreach ($mapping in $VolumeMappings) {
        foreach ($version in @(1, 2, 3)) {
            Remove-PublisherEgsLegacyBundle -Path (Join-Path $mapping.RootPath `
                ".iscsi-reset\egs-manifests.v$version.json")
        }
        foreach ($fileName in @(
            "egs-programdata.v3.zip", "egs-programdata.v3.index.json"
        )) {
            Remove-PublisherEgsLegacyBundle -Path (Join-Path $mapping.RootPath `
                ".iscsi-reset\$fileName")
        }
        if ([string]$mapping.Name -cne [string]$anchor.Name) {
            foreach ($fileName in @("egs-state.v4.zip", "egs-state.v4.index.json")) {
                Remove-PublisherEgsLegacyBundle -Path (Join-Path $mapping.RootPath `
                    ".iscsi-reset\$fileName")
            }
        }
    }
    foreach ($mapping in $VolumeMappings) {
        foreach ($version in @(1, 2, 3)) {
            if (Test-Path -LiteralPath (Join-Path $mapping.RootPath `
                ".iscsi-reset\egs-manifests.v$version.json")) {
                throw "Legacy Epic Games bundle removal failed for volume $($mapping.Name)"
            }
        }
        foreach ($fileName in @(
            "egs-programdata.v3.zip", "egs-programdata.v3.index.json"
        )) {
            if (Test-Path -LiteralPath (Join-Path $mapping.RootPath `
                ".iscsi-reset\$fileName")) {
                throw "Legacy Epic Games state removal failed for volume $($mapping.Name)"
            }
        }
        if ([string]$mapping.Name -cne [string]$anchor.Name) {
            foreach ($fileName in @("egs-state.v4.zip", "egs-state.v4.index.json")) {
                if (Test-Path -LiteralPath (Join-Path $mapping.RootPath `
                    ".iscsi-reset\$fileName")) {
                    throw "Epic Games state exists outside the anchor volume"
                }
            }
        }
    }
    Assert-PublisherEgsAggressivePayload -ArchivePath $archivePath -IndexPath $indexPath `
        -IndexData $indexData
    Assert-EgsLauncherStopped
    Wait-EgsSharedInstallDbIdle -InstallDbPath $SharedInstallDbPath
    return [pscustomobject]@{
        FileCount = @($indexData.Files).Count
        TotalBytes = [Int64]$indexData.TotalBytes
        SharedInstallDbFileCount = [int]$indexData.SharedInstallDbFileCount
        SharedInstallDbTotalBytes = [Int64]$indexData.SharedInstallDbTotalBytes
        ArchiveSha256 = [string]$archiveMetadata.archive_sha256
    }
}

function Read-PublisherManifest {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Publisher manifest not found: $Path" }
    $manifest = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ([int]$manifest.schema_version -ne 1) { throw "Unsupported publisher manifest schema" }
    if ([string]::IsNullOrWhiteSpace([string]$manifest.config_revision)) {
        throw "Publisher manifest has no config revision"
    }
    if ([string]::IsNullOrWhiteSpace([string]$manifest.target_iqn)) {
        throw "Publisher manifest has no target IQN"
    }
    if ($null -eq $manifest.portal -or
        [string]::IsNullOrWhiteSpace([string]$manifest.portal.address) -or
        [int]$manifest.portal.port -lt 1) {
        throw "Publisher manifest has an invalid portal"
    }
    $volumes = @($manifest.volumes)
    if ($volumes.Count -eq 0) { throw "Publisher manifest has no volumes" }
    $ids = @($volumes | ForEach-Object {
        Normalize-PublisherDiskId ([string]$_.disk_unique_id)
    })
    if (@($ids | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
        throw "Publisher manifest contains an empty disk ID"
    }
    if (@($ids | Select-Object -Unique).Count -ne $ids.Count) {
        throw "Publisher manifest contains duplicate disk IDs"
    }
    return $manifest
}

function Get-PublisherSession {
    param([Parameter(Mandatory = $true)][string]$TargetIqn)
    return @(Get-IscsiSession | Where-Object { $_.TargetNodeAddress -eq $TargetIqn })
}

function Get-PublisherSessionDisks {
    param([Parameter(Mandatory = $true)]$Session)
    return @($Session | Get-Disk)
}

function Assert-PublisherDisks {
    param(
        [Parameter(Mandatory = $true)]$ExpectedVolumes,
        [Parameter(Mandatory = $true)]$Disks
    )
    if ($Disks.Count -ne $ExpectedVolumes.Count) {
        throw "Publisher session exposed $($Disks.Count) disks; expected $($ExpectedVolumes.Count)"
    }
    $matched = @()
    foreach ($expected in $ExpectedVolumes) {
        $expectedId = Normalize-PublisherDiskId ([string]$expected.disk_unique_id)
        $matches = @($Disks | Where-Object {
            (Normalize-PublisherDiskId ([string]$_.UniqueId)) -eq $expectedId
        })
        if ($matches.Count -ne 1) {
            throw "Expected exactly one publisher disk for NAA $expectedId"
        }
        $matched += $matches[0]
    }
    return $matched
}

function Save-PublisherPending {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Manifest
    )
    $directory = Split-Path $Path -Parent
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $temporary = Join-Path $directory (".publisher-pending-" + [Guid]::NewGuid().ToString("N") + ".tmp")
    [ordered]@{
        schema_version = 1
        config_revision = [string]$Manifest.config_revision
        target_iqn = [string]$Manifest.target_iqn
        disk_unique_ids = @($Manifest.volumes | ForEach-Object {
            Normalize-PublisherDiskId ([string]$_.disk_unique_id)
        } | Sort-Object)
        created_at = [DateTime]::UtcNow.ToString("o")
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $temporary -Encoding UTF8
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Assert-PublisherPending {
    param(
        [Parameter(Mandatory = $true)]$Pending,
        [Parameter(Mandatory = $true)]$Manifest
    )
    if ([int]$Pending.schema_version -ne 1 -or
        [string]$Pending.config_revision -ne [string]$Manifest.config_revision -or
        [string]$Pending.target_iqn -ne [string]$Manifest.target_iqn) {
        throw "Pending state does not match the publisher manifest revision"
    }
    $pendingIds = @($Pending.disk_unique_ids | ForEach-Object {
        Normalize-PublisherDiskId ([string]$_)
    } | Sort-Object)
    $manifestIds = @($Manifest.volumes | ForEach-Object {
        Normalize-PublisherDiskId ([string]$_.disk_unique_id)
    } | Sort-Object)
    if (($pendingIds -join ",") -ne ($manifestIds -join ",")) {
        throw "Pending state disk IDs do not match the publisher manifest"
    }
}

function Set-PublisherDisksOffline {
    param([Parameter(Mandatory = $true)]$Disks)
    $errors = @()
    foreach ($disk in $Disks) {
        try {
            if (-not $disk.IsOffline) { Set-Disk -Number $disk.Number -IsOffline $true }
        } catch {
            $errors += "Disk $($disk.Number): $($_.Exception.Message)"
        }
    }
    foreach ($disk in $Disks) {
        try {
            $current = Get-Disk -Number $disk.Number
            if (-not $current.IsOffline) { $errors += "Disk $($disk.Number) did not go offline" }
        } catch {
            $errors += "Disk $($disk.Number) verification failed"
        }
    }
    if ($errors.Count -gt 0) { throw ($errors -join "; ") }
}

function Ensure-PublisherPortal {
    param([Parameter(Mandatory = $true)]$Portal)
    $existing = @(Get-IscsiTargetPortal | Where-Object {
        $_.TargetPortalAddress -eq [string]$Portal.address -and
        $_.TargetPortalPortNumber -eq [int]$Portal.port
    })
    if ($existing.Count -eq 0) {
        New-IscsiTargetPortal `
            -TargetPortalAddress ([string]$Portal.address) `
            -TargetPortalPortNumber ([int]$Portal.port) | Out-Null
    }
}

function Wait-PublisherTargetDiscovery {
    param(
        [Parameter(Mandatory = $true)][string]$TargetIqn,
        [Parameter(Mandatory = $true)]$Portal,
        [int]$MaxAttempts = 60,
        [int]$DelaySeconds = 1
    )
    if ($MaxAttempts -lt 1) { throw "MaxAttempts must be at least one" }
    if ($DelaySeconds -lt 0) { throw "DelaySeconds must not be negative" }

    $lastError = ""
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            Update-IscsiTargetPortal `
                -TargetPortalAddress ([string]$Portal.address) `
                -TargetPortalPortNumber ([int]$Portal.port) | Out-Null
        } catch {
            $lastError = $_.Exception.Message
        }

        try {
            $targets = @(Get-IscsiTarget | Where-Object {
                [string]$_.NodeAddress -eq $TargetIqn
            })
            if ($targets.Count -gt 0) { return $targets[0] }
        } catch {
            $lastError = $_.Exception.Message
        }

        if ($attempt -lt $MaxAttempts) {
            Start-Sleep -Seconds $DelaySeconds
        }
    }

    $message = "iSCSI target was not discovered after $MaxAttempts attempts: $TargetIqn"
    if (-not [string]::IsNullOrWhiteSpace($lastError)) {
        $message += ". Last discovery error: $lastError"
    }
    throw $message
}

function Connect-PublisherTarget {
    param([Parameter(Mandatory = $true)]$Manifest)
    $sessions = @(Get-PublisherSession -TargetIqn ([string]$Manifest.target_iqn))
    if ($sessions.Count -eq 0) {
        Ensure-PublisherPortal -Portal $Manifest.portal
        Wait-PublisherTargetDiscovery -TargetIqn ([string]$Manifest.target_iqn) `
            -Portal $Manifest.portal | Out-Null
        Connect-IscsiTarget `
            -NodeAddress ([string]$Manifest.target_iqn) `
            -TargetPortalAddress ([string]$Manifest.portal.address) `
            -TargetPortalPortNumber ([int]$Manifest.portal.port) `
            -IsPersistent $false `
            -IsMultipathEnabled $false `
            -AuthenticationType NONE | Out-Null
    } elseif ($sessions.Count -ne 1) {
        throw "Publisher target has $($sessions.Count) sessions; expected at most one"
    }

    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        $sessions = @(Get-PublisherSession -TargetIqn ([string]$Manifest.target_iqn))
        if ($sessions.Count -eq 1) {
            $disks = @(Get-PublisherSessionDisks -Session $sessions[0])
            if ($disks.Count -eq @($Manifest.volumes).Count) {
                return @(Assert-PublisherDisks -ExpectedVolumes @($Manifest.volumes) -Disks $disks)
            }
        }
        Start-Sleep -Seconds 1
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Publisher target did not reconnect with the expected disks"
}

function Invoke-PublisherDisconnect {
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)][string]$StatePath,
        [bool]$EgsSyncEnabled = $false,
        [ValidateSet("Disabled", "Enabled", "Aggressive")]
        [string]$EgsSyncMode = "Disabled",
        [string]$EpicManifestDirectory = "C:\ProgramData\Epic\EpicGamesLauncher\Data\Manifests",
        [string]$EpicProgramDataPath = "C:\ProgramData\Epic\EpicGamesLauncher\Data",
        [string]$EpicLauncherInstalledPath =
            "C:\ProgramData\Epic\UnrealEngineLauncher\LauncherInstalled.dat",
        [string]$EpicSharedInstallDbPath =
            "C:\ProgramData\Epic\EpicOnlineServicesShared\InstallHelper\InstalledItems",
        [string]$MajesticSettingsConfigPath = ""
    )
    if (Test-Path -LiteralPath $StatePath) {
        $pending = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
        Assert-PublisherPending -Pending $pending -Manifest $Manifest
        if (@(Get-PublisherSession -TargetIqn ([string]$Manifest.target_iqn)).Count -eq 0) {
            return
        }
        throw "Pending state exists but Publisher is still connected; recover manually"
    }
    $sessions = @(Get-PublisherSession -TargetIqn ([string]$Manifest.target_iqn))
    if ($sessions.Count -ne 1) { throw "Disconnect requires exactly one Publisher session" }
    $disks = @(Get-PublisherSessionDisks -Session $sessions[0])
    $matched = @(Assert-PublisherDisks -ExpectedVolumes @($Manifest.volumes) -Disks $disks)
    if ($EgsSyncEnabled -and $EgsSyncMode -eq "Disabled") {
        $EgsSyncMode = "Enabled"
    }
    $volumeMappings = @()
    if ($EgsSyncMode -ne "Disabled") {
        Stop-EgsLauncherProcesses
        $volumeMappings = @(Get-PublisherEgsVolumeMappings `
            -ExpectedVolumes @($Manifest.volumes) -Disks $matched)
        if ($EgsSyncMode -eq "Aggressive") {
            Export-PublisherEgsAggressiveBundles -Manifest $Manifest `
                -VolumeMappings $volumeMappings `
                -ManifestDirectory $EpicManifestDirectory `
                -ProgramDataPath $EpicProgramDataPath `
                -LauncherInstalledPath $EpicLauncherInstalledPath `
                -SharedInstallDbPath $EpicSharedInstallDbPath | Out-Null
        } else {
            Export-PublisherEgsBundles -Manifest $Manifest -VolumeMappings $volumeMappings `
                -ManifestDirectory $EpicManifestDirectory `
                -LauncherInstalledPath $EpicLauncherInstalledPath
        }
    }
    $majesticConfig = Get-MajesticSyncConfig -Path $MajesticSettingsConfigPath
    if ($majesticConfig.Present) {
        if ($volumeMappings.Count -eq 0) {
            $volumeMappings = @(Get-PublisherVolumeMappings `
                -ExpectedVolumes @($Manifest.volumes) -Disks $matched)
        }
        Invoke-PublisherMajesticSync -Config $majesticConfig -Manifest $Manifest `
            -VolumeMappings $volumeMappings
    }
    Save-PublisherPending -Path $StatePath -Manifest $Manifest
    Set-PublisherDisksOffline -Disks $matched
    Disconnect-IscsiTarget -NodeAddress ([string]$Manifest.target_iqn) -Confirm:$false
    if (@(Get-PublisherSession -TargetIqn ([string]$Manifest.target_iqn)).Count -ne 0) {
        throw "Publisher target did not disconnect"
    }
}

function Invoke-PublisherReconnect {
    param([Parameter(Mandatory = $true)]$Manifest, [Parameter(Mandatory = $true)][string]$StatePath)
    if (-not (Test-Path -LiteralPath $StatePath)) { throw "Publisher pending state not found" }
    $pending = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
    Assert-PublisherPending -Pending $pending -Manifest $Manifest
    $matched = @(Connect-PublisherTarget -Manifest $Manifest)
    foreach ($disk in $matched) {
        if ($disk.IsOffline) { Set-Disk -Number $disk.Number -IsOffline $false }
    }
    foreach ($disk in $matched) {
        if ((Get-Disk -Number $disk.Number).IsOffline) {
            throw "Disk $($disk.Number) did not come online"
        }
    }
    Remove-Item -LiteralPath $StatePath -Force
}

function Invoke-PublisherMain {
    param(
        [Parameter(Mandatory = $true)][ValidateSet("Disconnect", "Reconnect")][string]$RequestedAction,
        [Parameter(Mandatory = $true)][string]$PublisherManifestPath,
        [Parameter(Mandatory = $true)][string]$StatePath,
        [Parameter(Mandatory = $true)][string]$SyncConfigPath,
        [Parameter(Mandatory = $true)][string]$EpicManifestDirectory,
        [Parameter(Mandatory = $true)][string]$EpicProgramDataPath,
        [Parameter(Mandatory = $true)][string]$EpicLauncherInstalledPath,
        [Parameter(Mandatory = $true)][string]$EpicSharedInstallDbPath,
        [Parameter(Mandatory = $true)][string]$MajesticSettingsConfigPath
    )
    try {
        $manifest = Read-PublisherManifest -Path $PublisherManifestPath
        if ($RequestedAction -eq "Disconnect") {
            $egsSyncMode = Get-EgsManifestSyncMode -Path $SyncConfigPath
            Invoke-PublisherDisconnect -Manifest $manifest -StatePath $StatePath `
                -EgsSyncMode $egsSyncMode -EpicManifestDirectory $EpicManifestDirectory `
                -EpicProgramDataPath $EpicProgramDataPath `
                -EpicLauncherInstalledPath $EpicLauncherInstalledPath `
                -EpicSharedInstallDbPath $EpicSharedInstallDbPath `
                -MajesticSettingsConfigPath $MajesticSettingsConfigPath
            Write-Host "Publisher disconnected. Create and activate the release in the management UI."
        } else {
            Invoke-PublisherReconnect -Manifest $manifest -StatePath $StatePath
            Write-Host "Publisher reconnected and exact disks verified."
        }
        return 0
    } catch {
        Write-Warning $_.Exception.Message
        return 1
    }
}

if (-not $NoMain) {
    $exitCode = Invoke-PublisherMain `
        -RequestedAction $Action `
        -PublisherManifestPath $ManifestPath `
        -StatePath $PendingPath `
        -SyncConfigPath $EgsSyncConfigPath `
        -EpicManifestDirectory $EgsManifestDirectory `
        -EpicProgramDataPath $EgsProgramDataPath `
        -EpicLauncherInstalledPath $EgsLauncherInstalledPath `
        -EpicSharedInstallDbPath $EgsSharedInstallDbPath `
        -MajesticSettingsConfigPath $MajesticSyncConfigPath
    if ($PassThruExitCode) { Write-Output $exitCode } else { exit $exitCode }
}
