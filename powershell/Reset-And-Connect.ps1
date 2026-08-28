[CmdletBinding()]
param(
    [string]$ApiBaseUrl = "https://10.20.40.10:8443",
    [string]$TokenPath = "C:\ProgramData\IscsiReset\client.token",
    [string]$EgsSyncConfigPath = "",
    [string]$MajesticSyncConfigPath = "",
    [string]$Gta5RpSyncConfigPath = "",
    [int]$WaitTimeoutSeconds = 120,
    [string]$SimulationStatePath = "",
    [string]$SimulationSourceIp = "",
    [switch]$AllowHttpForSimulation,
    [switch]$PassThruExitCode,
    [switch]$NoMain
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
$script:DefaultEgsSyncConfigPath = Join-Path $PSScriptRoot "egs-sync.json"
$script:DefaultMajesticSyncConfigPath = Join-Path $PSScriptRoot "majestic-sync.json"
$script:DefaultGta5RpSyncConfigPath = Join-Path $PSScriptRoot "gta5rp-sync.json"

function Resolve-EgsSyncConfigPath {
    param([AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $script:DefaultEgsSyncConfigPath
    }
    return $Path
}

$EgsSyncConfigPath = Resolve-EgsSyncConfigPath -Path $EgsSyncConfigPath

function Resolve-MajesticSyncConfigPath {
    param([AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $script:DefaultMajesticSyncConfigPath
    }
    return $Path
}

$MajesticSyncConfigPath = Resolve-MajesticSyncConfigPath -Path $MajesticSyncConfigPath

function Resolve-Gta5RpSyncConfigPath {
    param([AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $script:DefaultGta5RpSyncConfigPath
    }
    return $Path
}

$Gta5RpSyncConfigPath = Resolve-Gta5RpSyncConfigPath -Path $Gta5RpSyncConfigPath

function Write-ResetLog {
    param(
        [Parameter(Mandatory = $true)][string]$Level,
        [Parameter(Mandatory = $true)][string]$Event,
        [Parameter(Mandatory = $true)][string]$RequestId,
        [string]$Message = "",
        [string]$LogPath = "",
        [hashtable]$Details = @{}
    )
    try {
        if ([string]::IsNullOrWhiteSpace($LogPath)) {
            if (-not [string]::IsNullOrWhiteSpace($script:SimulationStatePath)) {
                $LogPath = Join-Path (Split-Path $script:SimulationStatePath -Parent) "client.log.jsonl"
            } else {
                $LogPath = "C:\ProgramData\IscsiReset\logs\reset.jsonl"
            }
        }
        $directory = Split-Path $LogPath -Parent
        if (-not (Test-Path -LiteralPath $directory)) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
        }
        $record = [ordered]@{
            timestamp = [DateTime]::UtcNow.ToString("o")
            level = $Level
            event = $Event
            request_id = $RequestId
            message = $Message
        }
        foreach ($key in @($Details.Keys | Sort-Object)) {
            if (-not $record.Contains($key)) {
                $record[$key] = $Details[$key]
            }
        }
        $record | ConvertTo-Json -Compress | Add-Content -LiteralPath $LogPath -Encoding UTF8
    } catch {
        # Local diagnostics must never change the storage safety outcome.
    }
}

function Normalize-DiskId {
    param([Parameter(Mandatory = $true)][string]$Value)
    $normalized = ($Value -replace "\s", "").ToLowerInvariant()
    if ($normalized.StartsWith("0x")) {
        return $normalized.Substring(2)
    }
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
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
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
        throw "Majestic Launcher settings sync config is invalid"
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

function Get-Gta5RpSyncConfig {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
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
        throw "GTA5RP Launcher settings sync config is invalid"
    }
    $enabled = [string]$config.mode -eq "enabled"
    $sid = [string]$config.user_sid
    $profilePath = [string]$config.profile_path
    if ($enabled -and
        ($sid -notmatch '^S-1-[0-9]+(?:-[0-9]+)+$' -or
        $sid -eq "S-1-5-18" -or
        [string]::IsNullOrWhiteSpace($profilePath) -or
        -not [IO.Path]::IsPathRooted($profilePath))) {
        throw "GTA5RP Launcher settings sync user profile is invalid"
    }
    return [pscustomobject]@{
        Present = $true
        Enabled = $enabled
        UserSid = $sid
        ProfilePath = $profilePath
    }
}

function Initialize-Gta5RpRegistryNative {
    if ($null -ne ("IscsiReset.Gta5RpRegistryNative" -as [type])) { return }
    Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

namespace IscsiReset {
    public sealed class Gta5RpRegistryValueSnapshot {
        public string Name;
        public uint Type;
        public byte[] Data;
    }

    public sealed class Gta5RpRegistryKeySnapshot {
        public string RelativePath;
        public List<Gta5RpRegistryValueSnapshot> Values =
            new List<Gta5RpRegistryValueSnapshot>();
    }

    public sealed class Gta5RpRegistryTreeSnapshot {
        public string RootName;
        public List<Gta5RpRegistryKeySnapshot> Keys =
            new List<Gta5RpRegistryKeySnapshot>();
        public int ValueCount;
        public long TotalDataBytes;
    }

    public static class Gta5RpRegistryNative {
        private const int ERROR_SUCCESS = 0;
        private const int ERROR_FILE_NOT_FOUND = 2;
        private const int ERROR_MORE_DATA = 234;
        private const int ERROR_NO_MORE_ITEMS = 259;
        private const int KEY_READ = 0x20019;
        private const int KEY_WRITE = 0x20006;
        private const int DELETE = 0x00010000;
        private const int KEY_WOW64_64KEY = 0x0100;
        private const int REG_OPTION_OPEN_LINK = 0x00000008;
        private static readonly IntPtr HKEY_USERS =
            new IntPtr(unchecked((int)0x80000003));

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, EntryPoint = "RegOpenKeyExW")]
        private static extern int RegOpenKeyEx(
            IntPtr hKey, string subKey, int options, int desired, out IntPtr result);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode,
            EntryPoint = "RegOpenKeyTransactedW")]
        private static extern int RegOpenKeyTransacted(
            IntPtr hKey, string subKey, int options, int desired, out IntPtr result,
            IntPtr transaction, IntPtr extendedParameter);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode,
            EntryPoint = "RegCreateKeyTransactedW")]
        private static extern int RegCreateKeyTransacted(
            IntPtr hKey, string subKey, int reserved, string keyClass, int options,
            int desired, IntPtr securityAttributes, out IntPtr result,
            out int disposition, IntPtr transaction, IntPtr extendedParameter);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, EntryPoint = "RegEnumKeyExW")]
        private static extern int RegEnumKeyEx(
            IntPtr hKey, int index, StringBuilder name, ref int nameLength,
            IntPtr reserved, IntPtr keyClass, IntPtr classLength, out long lastWriteTime);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, EntryPoint = "RegEnumValueW")]
        private static extern int RegEnumValue(
            IntPtr hKey, int index, StringBuilder valueName, ref int valueNameLength,
            IntPtr reserved, out uint type, byte[] data, ref int dataLength);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode,
            EntryPoint = "RegQueryValueExW")]
        private static extern int RegQueryValueEx(
            IntPtr hKey, string valueName, IntPtr reserved, out uint type,
            byte[] data, ref int dataLength);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode,
            EntryPoint = "RegSetValueExW")]
        private static extern int RegSetValueEx(
            IntPtr hKey, string valueName, int reserved, uint type,
            byte[] data, int dataLength);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, EntryPoint = "RegDeleteTreeW")]
        private static extern int RegDeleteTree(IntPtr hKey, string subKey);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode,
            EntryPoint = "RegDeleteKeyTransactedW")]
        private static extern int RegDeleteKeyTransacted(
            IntPtr hKey, string subKey, int desired, int reserved,
            IntPtr transaction, IntPtr extendedParameter);

        [DllImport("advapi32.dll")]
        private static extern int RegCloseKey(IntPtr hKey);

        [DllImport("KtmW32.dll", CharSet = CharSet.Unicode,
            EntryPoint = "CreateTransaction", SetLastError = true)]
        private static extern IntPtr CreateTransactionNative(
            IntPtr attributes, IntPtr uow, int createOptions, int isolationLevel,
            int isolationFlags, int timeout, string description);

        [DllImport("KtmW32.dll", EntryPoint = "CommitTransaction", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CommitTransactionNative(IntPtr transaction);

        [DllImport("KtmW32.dll", EntryPoint = "RollbackTransaction", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool RollbackTransactionNative(IntPtr transaction);

        [DllImport("kernel32.dll", SetLastError = true, EntryPoint = "CloseHandle")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CloseHandleNative(IntPtr handle);

        private sealed class CaptureLimits {
            internal int Keys;
            internal int Values;
            internal long Bytes;
        }

        private static void Check(int status, string operation) {
            if (status != ERROR_SUCCESS) {
                throw new Win32Exception(status, operation);
            }
        }

        private static void ValidateType(uint type) {
            if (type != 0 && type != 1 && type != 2 && type != 3 && type != 4 &&
                type != 5 && type != 7 && type != 11) {
                throw new InvalidOperationException(
                    "GTA5RP registry contains an unsupported value type");
            }
        }

        private static List<string> GetSubKeyNames(IntPtr key) {
            List<string> names = new List<string>();
            for (int index = 0; ; index++) {
                StringBuilder name = new StringBuilder(256);
                int length = name.Capacity;
                long lastWrite;
                int status = RegEnumKeyEx(
                    key, index, name, ref length, IntPtr.Zero, IntPtr.Zero,
                    IntPtr.Zero, out lastWrite);
                if (status == ERROR_NO_MORE_ITEMS) { break; }
                Check(status, "RegEnumKeyExW");
                names.Add(name.ToString());
            }
            names.Sort(StringComparer.OrdinalIgnoreCase);
            return names;
        }

        private static List<string> GetValueNames(IntPtr key) {
            List<string> names = new List<string>();
            for (int index = 0; ; index++) {
                StringBuilder name = new StringBuilder(16384);
                int nameLength = name.Capacity;
                int dataLength = 0;
                uint type;
                int status = RegEnumValue(
                    key, index, name, ref nameLength, IntPtr.Zero, out type,
                    null, ref dataLength);
                if (status == ERROR_NO_MORE_ITEMS) { break; }
                if (status != ERROR_SUCCESS && status != ERROR_MORE_DATA) {
                    Check(status, "RegEnumValueW");
                }
                names.Add(name.ToString());
            }
            names.Sort(StringComparer.OrdinalIgnoreCase);
            return names;
        }

        private static Gta5RpRegistryValueSnapshot ReadValue(IntPtr key, string name) {
            int length = 0;
            uint type;
            int status = RegQueryValueEx(
                key, name, IntPtr.Zero, out type, null, ref length);
            Check(status, "RegQueryValueExW(size)");
            ValidateType(type);
            if (length < 0 || length > 4 * 1024 * 1024) {
                throw new InvalidOperationException(
                    "GTA5RP registry value exceeds its size limit");
            }
            byte[] data = new byte[length];
            int actual = length;
            status = RegQueryValueEx(
                key, name, IntPtr.Zero, out type, data, ref actual);
            Check(status, "RegQueryValueExW(data)");
            ValidateType(type);
            if (actual != data.Length) {
                Array.Resize(ref data, actual);
            }
            Gta5RpRegistryValueSnapshot value = new Gta5RpRegistryValueSnapshot();
            value.Name = name;
            value.Type = type;
            value.Data = data;
            return value;
        }

        private static void CaptureKey(
            IntPtr key, string relativePath, int depth, IntPtr transaction,
            bool transacted, Gta5RpRegistryTreeSnapshot tree, CaptureLimits limits) {
            if (depth > 16 || ++limits.Keys > 256) {
                throw new InvalidOperationException(
                    "GTA5RP registry tree exceeds its key limits");
            }
            Gta5RpRegistryKeySnapshot snapshot = new Gta5RpRegistryKeySnapshot();
            snapshot.RelativePath = relativePath;
            foreach (string valueName in GetValueNames(key)) {
                Gta5RpRegistryValueSnapshot value = ReadValue(key, valueName);
                if (++limits.Values > 1024) {
                    throw new InvalidOperationException(
                        "GTA5RP registry tree exceeds its value-count limit");
                }
                limits.Bytes += value.Data.LongLength;
                if (limits.Bytes > 16L * 1024L * 1024L) {
                    throw new InvalidOperationException(
                        "GTA5RP registry tree exceeds its total-data limit");
                }
                snapshot.Values.Add(value);
            }
            tree.Keys.Add(snapshot);
            foreach (string childName in GetSubKeyNames(key)) {
                IntPtr child;
                int status;
                int desired = KEY_READ | KEY_WOW64_64KEY;
                if (transacted) {
                    status = RegOpenKeyTransacted(
                        key, childName, 0, desired, out child, transaction,
                        IntPtr.Zero);
                } else {
                    status = RegOpenKeyEx(
                        key, childName, REG_OPTION_OPEN_LINK, desired, out child);
                }
                Check(status, "open GTA5RP registry subkey");
                try {
                    string childPath = relativePath.Length == 0
                        ? childName : relativePath + "\\" + childName;
                    CaptureKey(
                        child, childPath, depth + 1, transaction, transacted,
                        tree, limits);
                } finally {
                    RegCloseKey(child);
                }
            }
        }

        private static Gta5RpRegistryTreeSnapshot CaptureOpenedTree(
            IntPtr key, string treeRoot, IntPtr transaction, bool transacted) {
            Gta5RpRegistryTreeSnapshot tree = new Gta5RpRegistryTreeSnapshot();
            tree.RootName = treeRoot;
            CaptureLimits limits = new CaptureLimits();
            CaptureKey(key, "", 0, transaction, transacted, tree, limits);
            tree.Keys.Sort(delegate(
                Gta5RpRegistryKeySnapshot left,
                Gta5RpRegistryKeySnapshot right) {
                    return StringComparer.OrdinalIgnoreCase.Compare(
                        left.RelativePath, right.RelativePath);
                });
            tree.ValueCount = limits.Values;
            tree.TotalDataBytes = limits.Bytes;
            return tree;
        }

        public static Gta5RpRegistryTreeSnapshot CaptureTree(
            string hiveRootName, string treeRoot) {
            IntPtr key;
            int status = RegOpenKeyEx(
                HKEY_USERS, hiveRootName + "\\Software\\" + treeRoot,
                REG_OPTION_OPEN_LINK,
                KEY_READ | KEY_WOW64_64KEY, out key);
            Check(status, "open GTA5RP registry tree");
            try {
                return CaptureOpenedTree(key, treeRoot, IntPtr.Zero, false);
            } finally {
                RegCloseKey(key);
            }
        }

        public static Gta5RpRegistryTreeSnapshot CaptureTreeTransacted(
            IntPtr softwareKey, string treeRoot, IntPtr transaction) {
            IntPtr key;
            int status = RegOpenKeyTransacted(
                softwareKey, treeRoot, 0, KEY_READ | KEY_WOW64_64KEY,
                out key, transaction, IntPtr.Zero);
            Check(status, "open transacted GTA5RP registry tree");
            try {
                return CaptureOpenedTree(key, treeRoot, transaction, true);
            } finally {
                RegCloseKey(key);
            }
        }

        public static IntPtr BeginTransaction() {
            IntPtr transaction = CreateTransactionNative(
                IntPtr.Zero, IntPtr.Zero, 0, 0, 0, 0,
                "iSCSI Reset GTA5RP registry sync");
            if (transaction == new IntPtr(-1)) {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(), "CreateTransaction");
            }
            return transaction;
        }

        public static IntPtr OpenUserSoftwareTransacted(
            string hiveRootName, IntPtr transaction) {
            IntPtr key;
            int status = RegOpenKeyTransacted(
                HKEY_USERS, hiveRootName + "\\Software", 0,
                KEY_READ | KEY_WRITE | DELETE | KEY_WOW64_64KEY,
                out key, transaction, IntPtr.Zero);
            Check(status, "open transacted user Software key");
            return key;
        }

        private static void AssertKeyHasNoLinks(IntPtr key) {
            int length = 0;
            uint type;
            int status = RegQueryValueEx(
                key, "SymbolicLinkValue", IntPtr.Zero, out type, null, ref length);
            if (status == ERROR_SUCCESS && type == 6) {
                throw new InvalidOperationException(
                    "GTA5RP registry symbolic links are not supported");
            }
            if (status != ERROR_SUCCESS && status != ERROR_FILE_NOT_FOUND) {
                Check(status, "inspect GTA5RP registry key for links");
            }
            foreach (string childName in GetSubKeyNames(key)) {
                IntPtr child;
                status = RegOpenKeyEx(
                    key, childName, REG_OPTION_OPEN_LINK,
                    KEY_READ | KEY_WOW64_64KEY, out child);
                Check(status, "open GTA5RP registry key for link inspection");
                try {
                    AssertKeyHasNoLinks(child);
                } finally {
                    RegCloseKey(child);
                }
            }
        }

        public static void AssertTreeHasNoLinks(
            string hiveRootName, string treeRoot) {
            IntPtr key;
            int status = RegOpenKeyEx(
                HKEY_USERS, hiveRootName + "\\Software\\" + treeRoot,
                REG_OPTION_OPEN_LINK, KEY_READ | KEY_WOW64_64KEY, out key);
            if (status == ERROR_FILE_NOT_FOUND) { return; }
            Check(status, "open GTA5RP registry tree for link inspection");
            try {
                AssertKeyHasNoLinks(key);
            } finally {
                RegCloseKey(key);
            }
        }

        public static void DeleteTreeTransacted(
            IntPtr softwareKey, string treeRoot, IntPtr transaction) {
            IntPtr key;
            int status = RegOpenKeyTransacted(
                softwareKey, treeRoot, 0,
                KEY_READ | KEY_WRITE | DELETE | KEY_WOW64_64KEY,
                out key, transaction, IntPtr.Zero);
            if (status == ERROR_FILE_NOT_FOUND) { return; }
            Check(status, "open GTA5RP registry tree for deletion");
            try {
                Check(RegDeleteTree(key, null), "RegDeleteTreeW");
            } finally {
                RegCloseKey(key);
            }
            Check(RegDeleteKeyTransacted(
                softwareKey, treeRoot, KEY_WOW64_64KEY, 0,
                transaction, IntPtr.Zero), "RegDeleteKeyTransactedW");
        }

        public static void WriteTreeTransacted(
            IntPtr softwareKey, Gta5RpRegistryTreeSnapshot tree,
            IntPtr transaction) {
            foreach (Gta5RpRegistryKeySnapshot keySnapshot in tree.Keys) {
                string path = tree.RootName;
                if (keySnapshot.RelativePath.Length != 0) {
                    path += "\\" + keySnapshot.RelativePath;
                }
                IntPtr key;
                int disposition;
                int status = RegCreateKeyTransacted(
                    softwareKey, path, 0, null, 0,
                    KEY_READ | KEY_WRITE | DELETE | KEY_WOW64_64KEY,
                    IntPtr.Zero, out key, out disposition,
                    transaction, IntPtr.Zero);
                Check(status, "RegCreateKeyTransactedW");
                try {
                    foreach (Gta5RpRegistryValueSnapshot value in keySnapshot.Values) {
                        Check(RegSetValueEx(
                            key, value.Name, 0, value.Type,
                            value.Data, value.Data.Length), "RegSetValueExW");
                    }
                } finally {
                    RegCloseKey(key);
                }
            }
        }

        public static void CommitTransaction(IntPtr transaction) {
            if (!CommitTransactionNative(transaction)) {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(), "CommitTransaction");
            }
        }

        public static void RollbackTransaction(IntPtr transaction) {
            if (transaction != IntPtr.Zero) {
                RollbackTransactionNative(transaction);
            }
        }

        public static void CloseTransaction(IntPtr transaction) {
            if (transaction != IntPtr.Zero) { CloseHandleNative(transaction); }
        }

        public static void CloseRegistryKey(IntPtr key) {
            if (key != IntPtr.Zero) { RegCloseKey(key); }
        }
    }
}
"@
}

function Open-Gta5RpUserHive {
    param(
        [Parameter(Mandatory = $true)][string]$UserSid,
        [Parameter(Mandatory = $true)][string]$ProfilePath
    )
    if (Test-Path -LiteralPath "Registry::HKEY_USERS\$UserSid") {
        return [pscustomobject]@{ RootName = $UserSid; LoadedByHelper = $false }
    }
    $hivePath = Join-Path $ProfilePath "NTUSER.DAT"
    if (-not (Test-Path -LiteralPath $hivePath -PathType Leaf)) {
        throw "GTA5RP Launcher user NTUSER.DAT does not exist"
    }
    $hiveFile = Get-Item -LiteralPath $hivePath -Force
    if (([int]$hiveFile.Attributes -band [int][IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "GTA5RP Launcher user NTUSER.DAT must not be a reparse point"
    }
    $rootName = "IscsiResetGta5Rp_" + [Guid]::NewGuid().ToString("N")
    & reg.exe load "HKU\$rootName" $hivePath | Out-Null
    if ($LASTEXITCODE -ne 0 -or
        -not (Test-Path -LiteralPath "Registry::HKEY_USERS\$rootName")) {
        throw "GTA5RP Launcher user registry hive could not be loaded"
    }
    return [pscustomobject]@{ RootName = $rootName; LoadedByHelper = $true }
}

function Close-Gta5RpUserHive {
    param([Parameter(Mandatory = $true)]$Hive)
    if (-not [bool]$Hive.LoadedByHelper) { return }
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
    & reg.exe unload "HKU\$($Hive.RootName)" | Out-Null
    if ($LASTEXITCODE -ne 0 -or
        (Test-Path -LiteralPath "Registry::HKEY_USERS\$($Hive.RootName)")) {
        throw "GTA5RP Launcher user registry hive could not be unloaded"
    }
}

function ConvertTo-Gta5RpRegistryTreePayload {
    param([Parameter(Mandatory = $true)]$Tree)
    $keys = @()
    foreach ($key in @($Tree.Keys)) {
        $values = @()
        foreach ($value in @($key.Values)) {
            $bytes = [byte[]]$value.Data
            $values += [ordered]@{
                name = [string]$value.Name
                type = [int64]$value.Type
                length = [int64]$bytes.Length
                base64 = [Convert]::ToBase64String($bytes)
            }
        }
        $keys += [ordered]@{
            path = [string]$key.RelativePath
            values = $values
        }
    }
    $canonical = [ordered]@{
        root = [string]$Tree.RootName
        keys = $keys
    }
    $canonicalBytes = (New-Object Text.UTF8Encoding($false)).GetBytes(
        ($canonical | ConvertTo-Json -Depth 8 -Compress)
    )
    return [pscustomobject]@{
        Payload = [ordered]@{
            root = [string]$Tree.RootName
            sha256 = Get-EgsSha256Hex $canonicalBytes
            keys = $keys
        }
        CanonicalBytes = $canonicalBytes
        KeyCount = [int]@($keys).Count
        ValueCount = [int]$Tree.ValueCount
        TotalDataBytes = [int64]$Tree.TotalDataBytes
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
        throw "Majestic Launcher restarted during settings sync"
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

function Set-MajesticRegistryStringValue {
    param(
        [Parameter(Mandatory = $true)][string]$RootName,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Value
    )
    $users = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::Users,
        [Microsoft.Win32.RegistryView]::Default
    )
    $key = $null
    try {
        $key = $users.CreateSubKey("$RootName\Software\MAJESTIC-LAUNCHER")
        if ($null -eq $key) { throw "Majestic Launcher registry key could not be opened" }
        $key.SetValue($Name, $Value, [Microsoft.Win32.RegistryValueKind]::String)
    } finally {
        if ($null -ne $key) { $key.Dispose() }
        $users.Dispose()
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
                throw "Majestic Launcher registry value verification failed: $name"
            }
            $values[$name] = [string]$key.GetValue(
                $name,
                $null,
                [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
            )
        }
        return [pscustomobject]$values
    } finally {
        if ($null -ne $key) { $key.Dispose() }
        $users.Dispose()
    }
}

function Set-MajesticRegistryValues {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)]$RegistryValues
    )
    $hive = Open-MajesticUserHive -UserSid $Config.UserSid `
        -ProfilePath $Config.ProfilePath
    $failure = $null
    try {
        Set-MajesticRegistryStringValue -RootName $hive.RootName `
            -Name "lastVisitedServerID" `
            -Value ([string]$RegistryValues.lastVisitedServerID)
        Set-MajesticRegistryStringValue -RootName $hive.RootName `
            -Name "game_disk" -Value ([string]$RegistryValues.game_disk)
        $actual = Get-MajesticRegistryValuesFromRoot -RootName $hive.RootName
        if ([string]$actual.lastVisitedServerID -cne
            [string]$RegistryValues.lastVisitedServerID -or
            [string]$actual.game_disk -cne [string]$RegistryValues.game_disk) {
            throw "Majestic Launcher registry values did not verify"
        }
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

function Get-ClientEgsStateWarnings {
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
    if ($running.Count -ne 0) { throw "Epic Games Launcher restarted during manifest sync" }
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

function New-ApiException {
    param([int]$StatusCode, [string]$Code, [string]$Message)
    $exception = New-Object System.Exception($Message)
    $exception.Data["StatusCode"] = $StatusCode
    $exception.Data["Code"] = $Code
    return $exception
}

function Invoke-ResetRequest {
    param(
        [Parameter(Mandatory = $true)][ValidateSet("GET", "POST")][string]$Method,
        [Parameter(Mandatory = $true)][string]$Uri,
        [string]$Token = "",
        [Parameter(Mandatory = $true)][string]$RequestId,
        [int]$TimeoutSec = 180
    )
    $headers = @{ "X-Request-ID" = $RequestId }
    if (-not [string]::IsNullOrWhiteSpace($Token)) {
        $headers["Authorization"] = "Bearer $Token"
    }
    if (-not [string]::IsNullOrWhiteSpace($script:SimulationStatePath) -and
        -not [string]::IsNullOrWhiteSpace($script:SimulationSourceIp)) {
        $headers["X-Test-Source-IP"] = $script:SimulationSourceIp
    }
    try {
        return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers -TimeoutSec $TimeoutSec
    } catch {
        $statusCode = 0
        $code = "NETWORK_ERROR"
        $message = $_.Exception.Message
        if ($null -ne $_.Exception.Response) {
            try { $statusCode = [int]$_.Exception.Response.StatusCode } catch { $statusCode = 0 }
            try {
                $stream = $_.Exception.Response.GetResponseStream()
                $reader = New-Object System.IO.StreamReader($stream)
                $payload = $reader.ReadToEnd() | ConvertFrom-Json
                if ($null -ne $payload.error) {
                    $code = [string]$payload.error.code
                    $message = [string]$payload.error.message
                }
            } catch {
                # Preserve the original HTTP error when the body is not JSON.
            }
        }
        throw (New-ApiException -StatusCode $statusCode -Code $code -Message $message)
    }
}

function Wait-ResetApi {
    param(
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [Parameter(Mandatory = $true)][string]$RequestId,
        [int]$TimeoutSeconds = 120
    )
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $delay = 2
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            return Invoke-ResetRequest -Method GET -Uri "$BaseUrl/healthz" `
                -RequestId $RequestId -TimeoutSec 5
        } catch {
            Start-Sleep -Seconds $delay
            $delay = [Math]::Min(10, $delay * 2)
        }
    }
    throw (New-ApiException -StatusCode 0 -Code "API_TIMEOUT" -Message "Reset API did not become reachable")
}

function Invoke-PrepareWithRetry {
    param(
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [Parameter(Mandatory = $true)][string]$Token,
        [Parameter(Mandatory = $true)][string]$RequestId,
        [int]$TimeoutSeconds = 120
    )
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $delay = 2
    while ($true) {
        try {
            return Invoke-ResetRequest -Method POST -Uri "$BaseUrl/v1/prepare" -Token $Token -RequestId $RequestId
        } catch {
            $status = [int]$_.Exception.Data["StatusCode"]
            if (($status -notin @(409, 423, 503)) -or ([DateTime]::UtcNow -ge $deadline)) {
                throw
            }
            Start-Sleep -Seconds $delay
            $delay = [Math]::Min(10, $delay * 2)
        }
    }
}

function Read-SimulationState {
    if (-not (Test-Path -LiteralPath $script:SimulationStatePath)) {
        throw "Simulation state file does not exist: $script:SimulationStatePath"
    }
    return Get-Content -LiteralPath $script:SimulationStatePath -Raw | ConvertFrom-Json
}

function Save-SimulationState {
    param([Parameter(Mandatory = $true)]$State)
    $State | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:SimulationStatePath -Encoding UTF8
}

function Get-ResetSessions {
    param([Parameter(Mandatory = $true)][string]$TargetIqn)
    if (-not [string]::IsNullOrWhiteSpace($script:SimulationStatePath)) {
        $state = Read-SimulationState
        return @($state.sessions | Where-Object { $_.target_iqn -ceq $TargetIqn })
    }
    return @(Get-IscsiSession | Where-Object { $_.TargetNodeAddress -ceq $TargetIqn })
}

function Ensure-ResetPortal {
    param([Parameter(Mandatory = $true)]$Portal)
    if (-not [string]::IsNullOrWhiteSpace($script:SimulationStatePath)) { return }
    $existing = @(Get-IscsiTargetPortal | Where-Object {
        $_.TargetPortalAddress -eq [string]$Portal.address -and
        $_.TargetPortalPortNumber -eq [int]$Portal.port
    })
    if ($existing.Count -eq 0) {
        New-IscsiTargetPortal -TargetPortalAddress ([string]$Portal.address) -TargetPortalPortNumber ([int]$Portal.port) | Out-Null
    }
}

function Wait-ResetTargetDiscovery {
    param(
        [Parameter(Mandatory = $true)][string]$TargetIqn,
        [Parameter(Mandatory = $true)]$Portal,
        [Parameter(Mandatory = $true)][string]$RequestId,
        [int]$MaxAttempts = 60,
        [int]$DelaySeconds = 1
    )
    if ($MaxAttempts -lt 1) { throw "MaxAttempts must be at least one" }
    if ($DelaySeconds -lt 0) { throw "DelaySeconds must not be negative" }

    $startedAt = [DateTime]::UtcNow
    Write-ResetProgress -RequestId $RequestId -Event "target_discovery_started" `
        -Message "Waiting for the exact iSCSI target to appear" -Details @{
            target_iqn = $TargetIqn
            portal_address = [string]$Portal.address
            portal_port = [int]$Portal.port
            max_attempts = $MaxAttempts
        }

    if (-not [string]::IsNullOrWhiteSpace($script:SimulationStatePath)) {
        Write-ResetProgress -RequestId $RequestId -Event "target_discovered" `
            -Message "The exact iSCSI target is available" -Details @{
                target_iqn = $TargetIqn
                attempts = 1
                elapsed_seconds = 0
            }
        return [pscustomobject]@{ NodeAddress = $TargetIqn; Simulation = $true }
    }

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
            if ($targets.Count -gt 0) {
                $elapsed = [int][Math]::Floor(
                    ([DateTime]::UtcNow - $startedAt).TotalSeconds
                )
                Write-ResetProgress -RequestId $RequestId -Event "target_discovered" `
                    -Message "The exact iSCSI target is available" -Details @{
                        target_iqn = $TargetIqn
                        attempts = $attempt
                        elapsed_seconds = $elapsed
                    }
                return $targets[0]
            }
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
    throw (New-ApiException -StatusCode 0 -Code "TARGET_DISCOVERY_TIMEOUT" -Message $message)
}

function Connect-ResetTarget {
    param(
        [Parameter(Mandatory = $true)][string]$TargetIqn,
        [Parameter(Mandatory = $true)]$Portal
    )
    if (-not [string]::IsNullOrWhiteSpace($script:SimulationStatePath)) {
        $state = Read-SimulationState
        $sessions = @($state.sessions)
        $sessions += [pscustomobject]@{ target_iqn = $TargetIqn; persistent = $false }
        $state.sessions = $sessions
        Save-SimulationState $state
        return [pscustomobject]@{ TargetNodeAddress = $TargetIqn; Simulation = $true }
    }
    Connect-IscsiTarget -NodeAddress $TargetIqn `
        -TargetPortalAddress ([string]$Portal.address) `
        -TargetPortalPortNumber ([int]$Portal.port) `
        -IsPersistent $false `
        -IsMultipathEnabled $false `
        -AuthenticationType NONE | Out-Null
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        $session = @(Get-ResetSessions -TargetIqn $TargetIqn) | Select-Object -First 1
        if ($null -ne $session) { return $session }
        Start-Sleep -Seconds 1
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "iSCSI session did not appear: $TargetIqn"
}

function Disconnect-ResetTarget {
    param(
        [Parameter(Mandatory = $true)][string]$TargetIqn,
        [int]$MaxAttempts = 16,
        [int]$RetryAttempt = 6,
        [int]$DelayMilliseconds = 1000
    )
    if ($MaxAttempts -lt 1) { throw "MaxAttempts must be at least one" }
    if ($RetryAttempt -lt 1 -or $RetryAttempt -gt $MaxAttempts) {
        throw "RetryAttempt must be between one and MaxAttempts"
    }
    if ($DelayMilliseconds -lt 0) { throw "DelayMilliseconds must not be negative" }
    if (-not [string]::IsNullOrWhiteSpace($script:SimulationStatePath)) {
        $state = Read-SimulationState
        $state.sessions = @($state.sessions | Where-Object { $_.target_iqn -cne $TargetIqn })
        Save-SimulationState $state
        if (@(Get-ResetSessions -TargetIqn $TargetIqn).Count -eq 0) { return }
        throw "iSCSI target session remained connected after cleanup"
    }
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        if ($attempt -eq 1 -or $attempt -eq $RetryAttempt) {
            try {
                Disconnect-IscsiTarget -NodeAddress $TargetIqn -Confirm:$false `
                    -ErrorAction Stop | Out-Null
            } catch {
                # Verification below is authoritative because Windows may remove the
                # session even when the disconnect cmdlet reports a transient error.
            }
        }
        if (@(Get-ResetSessions -TargetIqn $TargetIqn).Count -eq 0) { return }
        if ($attempt -lt $MaxAttempts) {
            Start-Sleep -Milliseconds $DelayMilliseconds
        }
    }
    throw "iSCSI target session remained connected after cleanup"
}

function Get-ResetSessionDisks {
    param([Parameter(Mandatory = $true)]$Session)
    if (-not [string]::IsNullOrWhiteSpace($script:SimulationStatePath)) {
        $state = Read-SimulationState
        return @($state.disks | Where-Object { $_.target_iqn -eq $Session.TargetNodeAddress })
    }
    return @($Session | Get-Disk)
}

function Wait-ResetSessionDisks {
    param(
        [Parameter(Mandatory = $true)]$Session,
        [Parameter(Mandatory = $true)][int]$ExpectedCount,
        [int]$TimeoutSeconds = 30
    )
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $disks = @(Get-ResetSessionDisks -Session $Session)
        if ($disks.Count -ge $ExpectedCount) { return $disks }
        Start-Sleep -Seconds 1
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timed out waiting for $ExpectedCount iSCSI disks; observed $($disks.Count)"
}

function Write-ResetProgress {
    param(
        [string]$RequestId,
        [Parameter(Mandatory = $true)][string]$Event,
        [string]$Message = "",
        [hashtable]$Details = @{}
    )
    if (-not [string]::IsNullOrWhiteSpace($RequestId)) {
        Write-ResetLog -Level "INFO" -Event $Event -RequestId $RequestId `
            -Message $Message -Details $Details
    }
}

function Get-ResetExpectedLetter {
    param([Parameter(Mandatory = $true)]$Expected)
    $letter = ([string]$Expected.drive_letter).Trim().ToUpperInvariant()
    if ($letter -notmatch "^[A-Z]$") {
        throw "Invalid drive letter for volume $($Expected.name)"
    }
    return $letter
}

function Get-ResetDiskMappings {
    param([Parameter(Mandatory = $true)]$ExpectedVolumes, [Parameter(Mandatory = $true)]$Disks)
    if ($Disks.Count -ne $ExpectedVolumes.Count) {
        throw "Session exposed $($Disks.Count) disks; expected $($ExpectedVolumes.Count)"
    }

    $seenIds = @{}
    $seenLetters = @{}
    $mappings = @()
    foreach ($expected in $ExpectedVolumes) {
        $expectedId = Normalize-DiskId ([string]$expected.disk_unique_id)
        $desiredLetter = Get-ResetExpectedLetter -Expected $expected
        if ($seenIds.ContainsKey($expectedId)) { throw "Duplicate expected disk ID $expectedId" }
        if ($seenLetters.ContainsKey($desiredLetter)) {
            throw "Duplicate expected drive letter $desiredLetter`:"
        }
        $seenIds[$expectedId] = $true
        $seenLetters[$desiredLetter] = $true

        $matches = @($Disks | Where-Object {
            (Normalize-DiskId ([string]$_.UniqueId)) -eq $expectedId
        })
        if ($matches.Count -ne 1) {
            throw "Expected exactly one session disk for ID $expectedId"
        }
        if ($matches[0].IsReadOnly) {
            throw "Expected disk is unexpectedly read-only: $expectedId"
        }
        $mappings += [pscustomobject]@{
            Expected = $expected
            ExpectedId = $expectedId
            DesiredLetter = $desiredLetter
            Disk = $matches[0]
        }
    }
    return $mappings
}

function Get-ResetPartitionVolumes {
    param([Parameter(Mandatory = $true)]$Partition)
    return @($Partition | Get-Volume)
}

function Get-ResetDriveLetterVolumes {
    param([Parameter(Mandatory = $true)][char]$DriveLetter)
    return @(Get-Volume -DriveLetter $DriveLetter -ErrorAction SilentlyContinue)
}

function Get-ResetDriveLetterPartitions {
    param([Parameter(Mandatory = $true)][char]$DriveLetter)
    return @(Get-Partition -DriveLetter $DriveLetter -ErrorAction SilentlyContinue)
}

function Assert-ResetDesiredLettersPreflight {
    param([Parameter(Mandatory = $true)]$Mappings)
    $sessionDiskNumbers = @{}
    foreach ($mapping in $Mappings) {
        $sessionDiskNumbers[[int]$mapping.Disk.Number] = $true
    }

    foreach ($mapping in $Mappings) {
        $letter = [char]$mapping.DesiredLetter
        $volumes = @(Get-ResetDriveLetterVolumes -DriveLetter $letter)
        $partitions = @(Get-ResetDriveLetterPartitions -DriveLetter $letter)
        if ($volumes.Count -eq 0 -and $partitions.Count -eq 0) { continue }
        if ($volumes.Count -gt 1 -or $partitions.Count -ne 1) {
            throw "Drive letter $letter`: is occupied by an unverified device"
        }
        if (-not $sessionDiskNumbers.ContainsKey([int]$partitions[0].DiskNumber)) {
            throw "Drive letter $letter`: is occupied by a disk outside the client session"
        }
    }
}

function Wait-ResetVolumeAssignments {
    param(
        [Parameter(Mandatory = $true)]$Mappings,
        [int]$TimeoutSeconds = 30,
        [switch]$SkipOnline
    )
    if (-not $SkipOnline) {
        foreach ($mapping in $Mappings) {
            if ($mapping.Disk.IsOffline) {
                Set-Disk -Number $mapping.Disk.Number -IsOffline $false
            }
        }
    }

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $lastPending = "partition or volume metadata is not ready"
    do {
        $assignments = @()
        $pending = $false
        foreach ($mapping in $Mappings) {
            try {
                $partitions = @(Get-Partition -DiskNumber $mapping.Disk.Number | Where-Object {
                    $_.Type -notin @("Reserved", "System", "Recovery")
                })
            } catch {
                $partitions = @()
                $lastPending = $_.Exception.Message
            }
            if ($partitions.Count -gt 1) {
                throw "Disk $($mapping.ExpectedId) must have exactly one data partition"
            }
            if ($partitions.Count -eq 0) {
                $pending = $true
                continue
            }

            $partition = $partitions[0]
            try {
                $volumes = @(Get-ResetPartitionVolumes -Partition $partition)
            } catch {
                $volumes = @()
                $lastPending = $_.Exception.Message
            }
            if ($volumes.Count -gt 1) {
                throw "Partition for $($mapping.Expected.name) exposed more than one volume"
            }
            if ($volumes.Count -eq 0 -or
                [string]::IsNullOrWhiteSpace([string]$volumes[0].FileSystemLabel)) {
                $pending = $true
                continue
            }
            if ([string]$volumes[0].FileSystemLabel -ne [string]$mapping.Expected.label) {
                throw "Volume label mismatch for $($mapping.Expected.name)"
            }

            $assignments += [pscustomobject]@{
                Name = [string]$mapping.Expected.name
                ExpectedId = $mapping.ExpectedId
                DiskNumber = [int]$mapping.Disk.Number
                PartitionNumber = [int]$partition.PartitionNumber
                CurrentLetter = ([string]$partition.DriveLetter).ToUpperInvariant()
                DesiredLetter = $mapping.DesiredLetter
                ExpectedLabel = [string]$mapping.Expected.label
            }
        }
        if (-not $pending -and $assignments.Count -eq $Mappings.Count) {
            return $assignments
        }
        if ([DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Seconds 1
        }
    } while ([DateTime]::UtcNow -lt $deadline)

    throw "Timed out waiting for partition and volume metadata: $lastPending"
}

function Assert-ResetDriveLetterOwnership {
    param([Parameter(Mandatory = $true)]$Assignments)
    $sessionPartitions = @{}
    foreach ($assignment in $Assignments) {
        $key = "$($assignment.DiskNumber):$($assignment.PartitionNumber)"
        $sessionPartitions[$key] = $true
    }

    foreach ($assignment in $Assignments) {
        $letter = [char]$assignment.DesiredLetter
        $volumes = @(Get-ResetDriveLetterVolumes -DriveLetter $letter)
        $partitions = @(Get-ResetDriveLetterPartitions -DriveLetter $letter)
        if ($volumes.Count -eq 0 -and $partitions.Count -eq 0) { continue }
        if ($volumes.Count -ne 1 -or $partitions.Count -ne 1) {
            throw "Drive letter $letter`: is occupied by an unverified device"
        }
        $key = "$($partitions[0].DiskNumber):$($partitions[0].PartitionNumber)"
        if (-not $sessionPartitions.ContainsKey($key)) {
            throw "Drive letter $letter`: is occupied by a disk outside the client session"
        }
    }
}

function Set-ResetDriveLetters {
    param(
        [Parameter(Mandatory = $true)]$Mappings,
        [Parameter(Mandatory = $true)]$Assignments,
        [string]$RequestId = ""
    )
    Assert-ResetDriveLetterOwnership -Assignments $Assignments

    foreach ($assignment in $Assignments) {
        Write-ResetProgress -RequestId $RequestId -Event "disk_verified" `
            -Message "Client disk, partition, label, and requested letter verified" -Details @{
                disk_unique_id = $assignment.ExpectedId
                disk_number = $assignment.DiskNumber
                current_drive_letter = $assignment.CurrentLetter
                desired_drive_letter = $assignment.DesiredLetter
            }
    }

    # Remove only mismatched letters from the already-proven client partitions. This
    # breaks E<->F cycles before assigning the configured letters.
    foreach ($assignment in $Assignments) {
        if (-not [string]::IsNullOrWhiteSpace($assignment.CurrentLetter) -and
            $assignment.CurrentLetter -ne $assignment.DesiredLetter) {
            Remove-PartitionAccessPath -DiskNumber $assignment.DiskNumber `
                -PartitionNumber $assignment.PartitionNumber `
                -AccessPath "$($assignment.CurrentLetter):" -Confirm:$false
            Write-ResetProgress -RequestId $RequestId -Event "drive_letter_removed" `
                -Message "Removed an automatically assigned client drive letter" -Details @{
                    disk_unique_id = $assignment.ExpectedId
                    disk_number = $assignment.DiskNumber
                    current_drive_letter = $assignment.CurrentLetter
                    desired_drive_letter = $assignment.DesiredLetter
                }
        }
    }

    foreach ($assignment in $Assignments) {
        if ($assignment.CurrentLetter -ne $assignment.DesiredLetter) {
            Set-Partition -DiskNumber $assignment.DiskNumber `
                -PartitionNumber $assignment.PartitionNumber `
                -NewDriveLetter ([char]$assignment.DesiredLetter)
            Write-ResetProgress -RequestId $RequestId -Event "drive_letter_assigned" `
                -Message "Assigned the configured client drive letter" -Details @{
                    disk_unique_id = $assignment.ExpectedId
                    disk_number = $assignment.DiskNumber
                    current_drive_letter = $assignment.DesiredLetter
                    desired_drive_letter = $assignment.DesiredLetter
                }
        }
    }

    $verified = @(Wait-ResetVolumeAssignments -Mappings $Mappings -TimeoutSeconds 10 -SkipOnline)
    foreach ($assignment in $verified) {
        if ($assignment.CurrentLetter -ne $assignment.DesiredLetter) {
            throw "Drive letter verification failed for $($assignment.Name)"
        }
    }
}

function Mount-SimulationVolumes {
    param(
        [Parameter(Mandatory = $true)]$ExpectedVolumes,
        [Parameter(Mandatory = $true)]$Disks,
        [string]$RequestId = ""
    )
    if ($Disks.Count -ne $ExpectedVolumes.Count) {
        throw "Session exposed $($Disks.Count) disks; expected $($ExpectedVolumes.Count)"
    }
    $state = Read-SimulationState
    $sessionIds = @{}
    foreach ($disk in $Disks) {
        $sessionIds[(Normalize-DiskId ([string]$disk.unique_id))] = $true
    }

    $assignments = @()
    $seenIds = @{}
    $seenLetters = @{}
    foreach ($expected in $ExpectedVolumes) {
        $expectedId = Normalize-DiskId ([string]$expected.disk_unique_id)
        $desiredLetter = Get-ResetExpectedLetter -Expected $expected
        if ($seenIds.ContainsKey($expectedId)) { throw "Duplicate expected disk ID $expectedId" }
        if ($seenLetters.ContainsKey($desiredLetter)) {
            throw "Duplicate expected drive letter $desiredLetter`:"
        }
        $seenIds[$expectedId] = $true
        $seenLetters[$desiredLetter] = $true
        $matches = @($Disks | Where-Object {
            (Normalize-DiskId ([string]$_.unique_id)) -eq $expectedId
        })
        if ($matches.Count -ne 1) { throw "Expected exactly one disk for ID $expectedId" }
        $disk = $matches[0]
        if ($disk.is_read_only) { throw "Expected disk is read-only: $expectedId" }
        if ([string]$disk.label -ne [string]$expected.label) {
            throw "Volume label mismatch for $($expected.name)"
        }
        $occupied = @($state.disks | Where-Object {
            ([string]$_.drive_letter).ToUpperInvariant() -eq $desiredLetter -and
            -not $sessionIds.ContainsKey((Normalize-DiskId ([string]$_.unique_id)))
        })
        if ($occupied.Count -gt 0) {
            throw "Drive letter $desiredLetter`: is occupied by a disk outside the client session"
        }
        $assignments += [pscustomobject]@{
            Expected = $expected
            ExpectedId = $expectedId
            Disk = $disk
            CurrentLetter = ([string]$disk.drive_letter).ToUpperInvariant()
            DesiredLetter = $desiredLetter
        }
    }

    foreach ($assignment in $assignments) {
        Write-ResetProgress -RequestId $RequestId -Event "disk_verified" `
            -Message "Simulation client disk verified" -Details @{
                disk_unique_id = $assignment.ExpectedId
                current_drive_letter = $assignment.CurrentLetter
                desired_drive_letter = $assignment.DesiredLetter
            }
    }
    foreach ($assignment in $assignments) {
        foreach ($stateDisk in $state.disks) {
            if ((Normalize-DiskId ([string]$stateDisk.unique_id)) -eq $assignment.ExpectedId) {
                $stateDisk.is_offline = $false
                $stateDisk.drive_letter = $assignment.DesiredLetter
            }
        }
    }
    Save-SimulationState $state
}

function Mount-ResetVolumes {
    param(
        [Parameter(Mandatory = $true)]$ExpectedVolumes,
        [Parameter(Mandatory = $true)]$Disks,
        [string]$RequestId = ""
    )
    if (-not [string]::IsNullOrWhiteSpace($script:SimulationStatePath)) {
        Mount-SimulationVolumes -ExpectedVolumes $ExpectedVolumes -Disks $Disks `
            -RequestId $RequestId
        return
    }

    # Match the complete disk set before changing any disk state.
    $mappings = @(Get-ResetDiskMappings -ExpectedVolumes $ExpectedVolumes -Disks $Disks)
    Assert-ResetDesiredLettersPreflight -Mappings $mappings
    $assignments = @(Wait-ResetVolumeAssignments -Mappings $mappings -TimeoutSeconds 30)
    Set-ResetDriveLetters -Mappings $mappings -Assignments $assignments -RequestId $RequestId
}

function Write-EgsBytesAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][byte[]]$Bytes
    )
    $directory = Split-Path $Path -Parent
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $temporary = Join-Path $directory (".egs-write-" + [Guid]::NewGuid().ToString("N") + ".tmp")
    $backup = Join-Path $directory (".egs-write-" + [Guid]::NewGuid().ToString("N") + ".bak")
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

function Get-MajesticVolumeRoot {
    param([Parameter(Mandatory = $true)]$ExpectedVolume)
    $letter = ([string]$ExpectedVolume.drive_letter).Trim().ToUpperInvariant()
    if ($letter -notmatch '^[D-Z]$') {
        throw "Majestic Launcher settings volume has an invalid drive letter"
    }
    return "${letter}:\"
}

function Get-ClientMajesticBackupPayloadPath {
    param([Parameter(Mandatory = $true)]$ExpectedVolume)
    return Join-Path (Get-MajesticVolumeRoot -ExpectedVolume $ExpectedVolume) `
        ".iscsi-reset\majestic-launcher-backup"
}

function Test-ClientMajesticBackupLeafName {
    param([Parameter(Mandatory = $true)][string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name) -or $Name.Length -gt 255 -or
        $Name -in @(".", "..") -or $Name -match '[\\/:]' -or
        [IO.Path]::GetFileName($Name) -cne $Name) {
        return $false
    }
    return $true
}

function Assert-ClientMajesticBackupPayload {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        $BackupMap,
        [int]$MaximumFileCount = 64,
        [Int64]$MaximumTotalBytes = 8GB,
        [Int64]$MaximumFileBytes = 4GB
    )
    $root = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (-not $root.PSIsContainer -or
        (([int]$root.Attributes -band [int][IO.FileAttributes]::ReparsePoint) -ne 0)) {
        throw "Majestic Launcher backup payload directory is unsafe"
    }
    $children = @(Get-ChildItem -LiteralPath $root.FullName -Force)
    if ($children.Count -lt 1 -or $children.Count -gt $MaximumFileCount) {
        throw "Majestic Launcher backup payload file set is invalid"
    }
    $files = @{}
    $total = [Int64]0
    foreach ($item in $children) {
        $name = [string]$item.Name
        $length = [Int64]$item.Length
        if ($item.PSIsContainer -or -not (Test-ClientMajesticBackupLeafName $name) -or
            $files.ContainsKey($name) -or
            (([int]$item.Attributes -band [int][IO.FileAttributes]::ReparsePoint) -ne 0) -or
            $length -lt 0 -or $length -gt $MaximumFileBytes) {
            throw "Majestic Launcher backup payload file verification failed"
        }
        $files[$name] = $length
        $total += $length
        if ($total -gt $MaximumTotalBytes) {
            throw "Majestic Launcher backup payload exceeds its size limit"
        }
    }
    if ($null -ne $BackupMap) {
        foreach ($property in @($BackupMap.files.PSObject.Properties)) {
            $name = [string]$property.Name
            if (-not $files.ContainsKey($name) -or
                [Int64]$property.Value.size -ne [Int64]$files[$name]) {
                throw "Majestic Launcher backup payload does not match backup map"
            }
        }
    }
    return [pscustomobject]@{
        Path = $root.FullName
        Files = $files
        FileCount = [int]$children.Count
        TotalBytes = $total
    }
}

function ConvertFrom-ClientMajesticBackupMap {
    param([Parameter(Mandatory = $true)]$Map)
    $mapProperties = @($Map.PSObject.Properties.Name)
    if ([int]$Map.version -ne 1 -or $null -eq $Map.files -or
        $mapProperties.Count -ne 2 -or $mapProperties -notcontains "version" -or
        $mapProperties -notcontains "files") {
        throw "Majestic Launcher backup map metadata is invalid"
    }
    $properties = @($Map.files.PSObject.Properties)
    if ($properties.Count -lt 1 -or $properties.Count -gt 64) {
        throw "Majestic Launcher backup map file set is invalid"
    }
    foreach ($property in $properties) {
        $metadata = $property.Value
        $metadataProperties = @($metadata.PSObject.Properties.Name)
        $mtime = [Int64]0
        if (-not (Test-ClientMajesticBackupLeafName ([string]$property.Name)) -or
            $metadataProperties.Count -ne 3 -or
            $metadataProperties -notcontains "size" -or
            $metadataProperties -notcontains "mtimeNs" -or
            $metadataProperties -notcontains "finalHash" -or
            [Int64]$metadata.size -lt 0 -or [Int64]$metadata.size -gt 4GB -or
            -not [Int64]::TryParse([string]$metadata.mtimeNs, [ref]$mtime) -or
            [string]$metadata.finalHash -notmatch '^[0-9A-Fa-f]{16}$') {
            throw "Majestic Launcher backup map contains invalid file metadata"
        }
    }
    return $Map
}

function Get-ClientMajesticGameDisk {
    param([Parameter(Mandatory = $true)][byte[]]$PrefsBytes)
    try {
        $strictUtf8 = New-Object Text.UTF8Encoding($false, $true)
        $prefs = $strictUtf8.GetString($PrefsBytes) | ConvertFrom-Json
    } catch {
        throw "Majestic Launcher prefs payload is not valid UTF-8 JSON"
    }
    $gameDisk = ([string]$prefs.gameDisk).Trim().ToUpperInvariant()
    if ($gameDisk -notmatch '^[D-Z]:$') {
        throw "Majestic Launcher prefs gameDisk is missing or invalid"
    }
    return $gameDisk
}

function Get-ClientMajesticAnchorVolume {
    param(
        [Parameter(Mandatory = $true)]$ExpectedVolumes,
        [Parameter(Mandatory = $true)][string]$GameDisk
    )
    $letter = $GameDisk.Substring(0, 1)
    $matches = @($ExpectedVolumes | Where-Object {
        ([string]$_.drive_letter).Trim().ToUpperInvariant() -ceq $letter
    })
    if ($matches.Count -ne 1) {
        throw "Majestic Launcher gameDisk must match exactly one mounted client volume"
    }
    return $matches[0]
}

function Get-ClientMajesticBundle {
    param(
        [Parameter(Mandatory = $true)]$ExpectedVolumes,
        [Parameter(Mandatory = $true)][string]$ConfigRevision
    )
    if (@($ExpectedVolumes).Count -eq 0) {
        throw "Majestic Launcher settings require at least one mounted volume"
    }
    $commonBytes = $null
    $commonSha = ""
    foreach ($volume in $ExpectedVolumes) {
        $root = Get-MajesticVolumeRoot -ExpectedVolume $volume
        $path = Join-Path $root ".iscsi-reset\majestic-launcher-settings.v2.json"
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Majestic Launcher settings bundle is missing"
        }
        $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if ((([int]$item.Attributes -band [int][IO.FileAttributes]::ReparsePoint) -ne 0) -or
            [Int64]$item.Length -lt 1 -or [Int64]$item.Length -gt 48MB) {
            throw "Majestic Launcher settings bundle file is unsafe"
        }
        $bytes = [IO.File]::ReadAllBytes($path)
        $sha = Get-EgsSha256Hex $bytes
        if ($null -eq $commonBytes) {
            $commonBytes = $bytes
            $commonSha = $sha
        } elseif ($bytes.Length -ne $commonBytes.Length -or $sha -ne $commonSha) {
            throw "Majestic Launcher settings bundles do not match"
        }
    }
    try {
        $strictUtf8 = New-Object Text.UTF8Encoding($false, $true)
        $bundle = $strictUtf8.GetString($commonBytes) | ConvertFrom-Json
    } catch {
        throw "Majestic Launcher settings bundle is not valid UTF-8 JSON"
    }
    if ([int]$bundle.schema_version -ne 2 -or
        [string]$bundle.config_revision -cne $ConfigRevision -or
        $null -eq $bundle.files -or $null -eq $bundle.registry -or
        $null -eq $bundle.backup_map -or
        $bundle.PSObject.Properties.Name -contains "backup_directory") {
        throw "Majestic Launcher settings bundle metadata is invalid"
    }
    $prefsBytes = ConvertFrom-MajesticFilePayload `
        -Payload $bundle.files.prefs_latest_json -Description "prefs" `
        -MaximumBytes 1MB -RequireJson
    $majesticBytes = ConvertFrom-MajesticFilePayload `
        -Payload $bundle.files.multiplayer_majestic_json -Description "majestic config" `
        -MaximumBytes 1MB -RequireJson
    $hashMapBytes = ConvertFrom-MajesticFilePayload `
        -Payload $bundle.files.hash_map_v3_ro_json -Description "verification hash map" `
        -MaximumBytes 16MB -RequireJson
    $hashMapGeneralBytes = ConvertFrom-MajesticFilePayload `
        -Payload $bundle.files.hash_map_v3_json -Description "general verification hash map" `
        -MaximumBytes 16MB -RequireJson
    $backupMap = ConvertFrom-ClientMajesticBackupMap -Map $bundle.backup_map
    $prefsGameDisk = Get-ClientMajesticGameDisk -PrefsBytes $prefsBytes
    $anchor = Get-ClientMajesticAnchorVolume -ExpectedVolumes $ExpectedVolumes `
        -GameDisk $prefsGameDisk
    $backupSourcePath = Get-ClientMajesticBackupPayloadPath -ExpectedVolume $anchor
    $backupMetadata = Assert-ClientMajesticBackupPayload `
        -Path $backupSourcePath -BackupMap $backupMap
    $lastServer = [string]$bundle.registry.lastVisitedServerID
    $gameDisk = [string]$bundle.registry.game_disk
    if ([string]::IsNullOrWhiteSpace($lastServer) -or $lastServer.Length -gt 1024 -or
        [string]::IsNullOrWhiteSpace($gameDisk) -or $gameDisk.Length -gt 1024) {
        throw "Majestic Launcher registry payload is invalid"
    }
    return [pscustomobject]@{
        PrefsBytes = $prefsBytes
        MajesticBytes = $majesticBytes
        HashMapBytes = $hashMapBytes
        HashMapGeneralBytes = $hashMapGeneralBytes
        BackupMap = $backupMap
        BackupSourcePath = $backupMetadata.Path
        BackupFileCount = [int]$backupMetadata.FileCount
        BackupTotalBytes = [Int64]$backupMetadata.TotalBytes
        GameDisk = $prefsGameDisk
        Registry = [pscustomobject]@{
            lastVisitedServerID = $lastServer
            game_disk = $gameDisk
        }
        BundleSha256 = $commonSha
    }
}

function ConvertFrom-MajesticFilePayload {
    param(
        [Parameter(Mandatory = $true)]$Payload,
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $true)][Int64]$MaximumBytes,
        [switch]$RequireJson
    )
    if ($null -eq $Payload) {
        throw "Majestic Launcher $Description payload is missing"
    }
    try {
        $bytes = [Convert]::FromBase64String([string]$Payload.base64)
    } catch {
        throw "Majestic Launcher $Description payload is not valid Base64"
    }
    if ($bytes.Length -lt 1 -or $bytes.Length -gt $MaximumBytes -or
        [Int64]$Payload.length -ne [Int64]$bytes.Length -or
        [string]$Payload.sha256 -notmatch '^[0-9a-f]{64}$' -or
        (Get-EgsSha256Hex $bytes) -ne [string]$Payload.sha256) {
        throw "Majestic Launcher $Description payload verification failed"
    }
    if ($RequireJson) {
        try {
            $strictUtf8 = New-Object Text.UTF8Encoding($false, $true)
            $strictUtf8.GetString($bytes) | ConvertFrom-Json | Out-Null
        } catch {
            throw "Majestic Launcher $Description payload is not valid UTF-8 JSON"
        }
    }
    return $bytes
}

function Get-MajesticProfileTargets {
    param([Parameter(Mandatory = $true)][string]$ProfilePath)
    $profile = Get-Item -LiteralPath $ProfilePath -Force -ErrorAction Stop
    if (-not $profile.PSIsContainer -or
        (([int]$profile.Attributes -band [int][IO.FileAttributes]::ReparsePoint) -ne 0)) {
        throw "Majestic Launcher target profile is unsafe"
    }
    $directory = $profile.FullName
    foreach ($segment in @("AppData", "Roaming", "majestic-launcher")) {
        $directory = Join-Path $directory $segment
        if (Test-Path -LiteralPath $directory) {
            $item = Get-Item -LiteralPath $directory -Force
        } else {
            New-Item -ItemType Directory -Path $directory | Out-Null
            $item = Get-Item -LiteralPath $directory -Force
        }
        if (-not $item.PSIsContainer -or
            (([int]$item.Attributes -band [int][IO.FileAttributes]::ReparsePoint) -ne 0)) {
            throw "Majestic Launcher target directory is unsafe"
        }
    }
    $launcherDirectory = $directory
    $multiplayerDirectory = Join-Path $launcherDirectory "Multiplayer"
    if (Test-Path -LiteralPath $multiplayerDirectory) {
        $item = Get-Item -LiteralPath $multiplayerDirectory -Force
    } else {
        New-Item -ItemType Directory -Path $multiplayerDirectory | Out-Null
        $item = Get-Item -LiteralPath $multiplayerDirectory -Force
    }
    if (-not $item.PSIsContainer -or
        (([int]$item.Attributes -band [int][IO.FileAttributes]::ReparsePoint) -ne 0)) {
        throw "Majestic Launcher Multiplayer target directory is unsafe"
    }
    $targets = [ordered]@{
        Prefs = Join-Path $launcherDirectory "prefs.latest.json"
        Majestic = Join-Path $multiplayerDirectory "majestic.json"
        HashMap = Join-Path $launcherDirectory "hashMap_v3_RO.json"
        HashMapGeneral = Join-Path $launcherDirectory "hashMap_v3.json"
        BackupMap = Join-Path $launcherDirectory "backupMap.json"
        BackupDirectory = Join-Path $multiplayerDirectory "backup"
    }
    foreach ($target in @(
        $targets.Prefs, $targets.Majestic, $targets.HashMap,
        $targets.HashMapGeneral, $targets.BackupMap
    )) {
        if (Test-Path -LiteralPath $target) {
            $item = Get-Item -LiteralPath $target -Force
            if ($item.PSIsContainer -or
                (([int]$item.Attributes -band [int][IO.FileAttributes]::ReparsePoint) -ne 0)) {
                throw "Majestic Launcher target file is unsafe"
            }
        }
    }
    if (Test-Path -LiteralPath $targets.BackupDirectory) {
        $backupItem = Get-Item -LiteralPath $targets.BackupDirectory -Force
        if (-not $backupItem.PSIsContainer) {
            throw "Majestic Launcher target backup path is unsafe"
        }
    }
    return [pscustomobject]$targets
}

function Commit-MajesticFile {
    param(
        [Parameter(Mandatory = $true)][string]$StagePath,
        [Parameter(Mandatory = $true)][string]$TargetPath
    )
    $backup = Join-Path (Split-Path $TargetPath -Parent) (
        ".majestic-file-" + [Guid]::NewGuid().ToString("N") + ".bak"
    )
    try {
        if (Test-Path -LiteralPath $TargetPath) {
            [IO.File]::Replace($StagePath, $TargetPath, $backup)
        } else {
            [IO.File]::Move($StagePath, $TargetPath)
        }
    } finally {
        Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
    }
}

function Write-MajesticStageFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][string]$Description
    )
    [IO.File]::WriteAllBytes($Path, $Bytes)
    if ((Get-EgsFileSha256Hex $Path) -ne (Get-EgsSha256Hex $Bytes)) {
        throw "Majestic Launcher $Description staging verification failed"
    }
}

function ConvertTo-ClientMajesticBackupMapBytes {
    param(
        [Parameter(Mandatory = $true)]$BackupMap,
        [Parameter(Mandatory = $true)][string]$BackupDirectory
    )
    $rewritten = [ordered]@{
        version = [int]$BackupMap.version
        backupDir = $BackupDirectory
        files = $BackupMap.files
    }
    $json = $rewritten | ConvertTo-Json -Depth 8 -Compress
    return (New-Object Text.UTF8Encoding($false)).GetBytes($json)
}

function Remove-MajesticBackupDirectoryEntry {
    param([Parameter(Mandatory = $true)][string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) { return }
    if (-not $item.PSIsContainer) {
        throw "Majestic Launcher backup target is not a directory"
    }
    if ((([int]$item.Attributes -band [int][IO.FileAttributes]::ReparsePoint) -ne 0)) {
        [IO.Directory]::Delete($item.FullName, $false)
    } else {
        $pending = New-Object 'System.Collections.Generic.Stack[string]'
        $pending.Push($item.FullName)
        while ($pending.Count -gt 0) {
            $directory = $pending.Pop()
            foreach ($child in @(Get-ChildItem -LiteralPath $directory -Force)) {
                if ((([int]$child.Attributes -band
                    [int][IO.FileAttributes]::ReparsePoint) -ne 0)) {
                    throw "Majestic Launcher backup directory contains a reparse point"
                }
                if ($child.PSIsContainer) { $pending.Push($child.FullName) }
            }
        }
        Remove-Item -LiteralPath $item.FullName -Recurse -Force
    }
}

function New-MajesticBackupJunction {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Target
    )
    $itemType = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        "Junction"
    } else {
        # The non-Windows branch exists only for the portable Pester suite.
        "SymbolicLink"
    }
    New-Item -ItemType $itemType -Path $Path -Target $Target -ErrorAction Stop | Out-Null
}

function Get-MajesticBackupJunctionTarget {
    param([Parameter(Mandatory = $true)][string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (-not $item.PSIsContainer -or
        (([int]$item.Attributes -band [int][IO.FileAttributes]::ReparsePoint) -eq 0)) {
        throw "Majestic Launcher backup junction is not active"
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

function Assert-MajesticBackupJunction {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)]$BackupMap
    )
    $actualTarget = Get-MajesticBackupJunctionTarget -Path $Path
    $expectedTarget = ConvertTo-EgsCanonicalPath $SourcePath
    if (-not $actualTarget.Equals(
        $expectedTarget, [StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Majestic Launcher backup junction points to another directory"
    }
    Assert-ClientMajesticBackupPayload -Path $SourcePath `
        -BackupMap $BackupMap | Out-Null
}

function Set-MajesticBackupJunction {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)]$BackupMap
    )
    $current = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -ne $current -and
        (([int]$current.Attributes -band [int][IO.FileAttributes]::ReparsePoint) -ne 0)) {
        try {
            Assert-MajesticBackupJunction -Path $Path -SourcePath $SourcePath `
                -BackupMap $BackupMap
            return
        } catch {
            [IO.Directory]::Delete($current.FullName, $false)
        }
    }
    $parent = Split-Path $Path -Parent
    $stage = Join-Path $parent (".majestic-backup-" + [Guid]::NewGuid().ToString("N") + ".tmp")
    $previous = Join-Path $parent ".iscsi-reset-majestic-backup.previous"
    try {
        Remove-MajesticBackupDirectoryEntry -Path $stage
        Remove-MajesticBackupDirectoryEntry -Path $previous
        New-MajesticBackupJunction -Path $stage -Target $SourcePath
        Assert-MajesticBackupJunction -Path $stage -SourcePath $SourcePath `
            -BackupMap $BackupMap
        $current = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        if ($null -ne $current) {
            if ((([int]$current.Attributes -band [int][IO.FileAttributes]::ReparsePoint) -ne 0)) {
                [IO.Directory]::Delete($current.FullName, $false)
            } else {
                [IO.Directory]::Move($current.FullName, $previous)
            }
        }
        [IO.Directory]::Move($stage, $Path)
        Assert-MajesticBackupJunction -Path $Path -SourcePath $SourcePath `
            -BackupMap $BackupMap
        Remove-MajesticBackupDirectoryEntry -Path $previous
    } finally {
        Remove-MajesticBackupDirectoryEntry -Path $stage
    }
}

function Invoke-ClientMajesticSettingsSync {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)]$ExpectedVolumes,
        [Parameter(Mandatory = $true)][string]$ConfigRevision
    )
    $bundle = Get-ClientMajesticBundle -ExpectedVolumes $ExpectedVolumes `
        -ConfigRevision $ConfigRevision
    Stop-MajesticLauncherProcesses
    Assert-MajesticLauncherStopped
    $targets = Get-MajesticProfileTargets -ProfilePath $Config.ProfilePath
    $rewrittenBackupMapBytes = ConvertTo-ClientMajesticBackupMapBytes `
        -BackupMap $bundle.BackupMap -BackupDirectory $targets.BackupDirectory
    $stages = [ordered]@{
        Prefs = Join-Path (Split-Path $targets.Prefs -Parent) `
            (".majestic-prefs-" + [Guid]::NewGuid().ToString("N") + ".tmp")
        Majestic = Join-Path (Split-Path $targets.Majestic -Parent) `
            (".majestic-config-" + [Guid]::NewGuid().ToString("N") + ".tmp")
        HashMap = Join-Path (Split-Path $targets.HashMap -Parent) `
            (".majestic-hashmap-" + [Guid]::NewGuid().ToString("N") + ".tmp")
        HashMapGeneral = Join-Path (Split-Path $targets.HashMapGeneral -Parent) `
            (".majestic-hashmap-general-" + [Guid]::NewGuid().ToString("N") + ".tmp")
        BackupMap = Join-Path (Split-Path $targets.BackupMap -Parent) `
            (".majestic-backup-map-" + [Guid]::NewGuid().ToString("N") + ".tmp")
    }
    $markerInvalidated = $false
    $completed = $false
    try {
        Write-MajesticStageFile -Path $stages.Prefs -Bytes $bundle.PrefsBytes `
            -Description "prefs"
        Write-MajesticStageFile -Path $stages.Majestic -Bytes $bundle.MajesticBytes `
            -Description "majestic config"
        Write-MajesticStageFile -Path $stages.HashMap -Bytes $bundle.HashMapBytes `
            -Description "verification hash map"
        Write-MajesticStageFile -Path $stages.HashMapGeneral `
            -Bytes $bundle.HashMapGeneralBytes -Description "general verification hash map"
        Write-MajesticStageFile -Path $stages.BackupMap `
            -Bytes $rewrittenBackupMapBytes -Description "backup map"
        Remove-Item -LiteralPath $targets.HashMap -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $targets.HashMapGeneral -Force -ErrorAction SilentlyContinue
        $markerInvalidated = $true
        if ((Test-Path -LiteralPath $targets.HashMap) -or
            (Test-Path -LiteralPath $targets.HashMapGeneral)) {
            throw "Majestic Launcher verification hash maps could not be invalidated"
        }
        Set-MajesticRegistryValues -Config $Config -RegistryValues $bundle.Registry
        Assert-MajesticLauncherStopped
        Commit-MajesticFile -StagePath $stages.Prefs -TargetPath $targets.Prefs
        Commit-MajesticFile -StagePath $stages.Majestic -TargetPath $targets.Majestic
        Set-MajesticBackupJunction -Path $targets.BackupDirectory `
            -SourcePath $bundle.BackupSourcePath -BackupMap $bundle.BackupMap
        Commit-MajesticFile -StagePath $stages.BackupMap -TargetPath $targets.BackupMap
        Assert-MajesticLauncherStopped
        Commit-MajesticFile -StagePath $stages.HashMapGeneral `
            -TargetPath $targets.HashMapGeneral
        Commit-MajesticFile -StagePath $stages.HashMap -TargetPath $targets.HashMap
        foreach ($check in @(
            [pscustomobject]@{ Path = $targets.Prefs; Bytes = $bundle.PrefsBytes },
            [pscustomobject]@{ Path = $targets.Majestic; Bytes = $bundle.MajesticBytes },
            [pscustomobject]@{
                Path = $targets.BackupMap; Bytes = $rewrittenBackupMapBytes
            },
            [pscustomobject]@{
                Path = $targets.HashMapGeneral; Bytes = $bundle.HashMapGeneralBytes
            },
            [pscustomobject]@{ Path = $targets.HashMap; Bytes = $bundle.HashMapBytes }
        )) {
            if (-not (Test-Path -LiteralPath $check.Path -PathType Leaf) -or
                (Get-EgsFileSha256Hex $check.Path) -ne
                (Get-EgsSha256Hex $check.Bytes)) {
                throw "Majestic Launcher target file verification failed"
            }
        }
        Assert-MajesticBackupJunction -Path $targets.BackupDirectory `
            -SourcePath $bundle.BackupSourcePath -BackupMap $bundle.BackupMap
        Assert-MajesticLauncherStopped
        $completed = $true
    } finally {
        foreach ($stagePath in @($stages.Values)) {
            Remove-Item -LiteralPath $stagePath -Force -ErrorAction SilentlyContinue
        }
        if ($markerInvalidated -and -not $completed) {
            Remove-Item -LiteralPath $targets.HashMap -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $targets.HashMapGeneral -Force `
                -ErrorAction SilentlyContinue
            if ((Test-Path -LiteralPath $targets.HashMap) -or
                (Test-Path -LiteralPath $targets.HashMapGeneral)) {
                throw "Majestic Launcher verification hash maps remained active after failure"
            }
        }
    }
    return [pscustomobject]@{
        BundleSha256 = $bundle.BundleSha256
        PrefsLength = [Int64]$bundle.PrefsBytes.Length
        HashMapLength = [Int64]$bundle.HashMapBytes.Length
        HashMapGeneralLength = [Int64]$bundle.HashMapGeneralBytes.Length
        BackupFileCount = [int]$bundle.BackupFileCount
        BackupTotalBytes = [Int64]$bundle.BackupTotalBytes
        FileCount = 5
        RegistryValueCount = 2
    }
}

function Get-Gta5RpVolumeRoot {
    param([Parameter(Mandatory = $true)]$ExpectedVolume)
    return Get-MajesticVolumeRoot -ExpectedVolume $ExpectedVolume
}

function ConvertFrom-ClientGta5RpRegistryTree {
    param(
        [Parameter(Mandatory = $true)]$Tree,
        [Parameter(Mandatory = $true)][string]$ExpectedRoot
    )
    if ([string]$Tree.root -cne $ExpectedRoot -or
        [string]$Tree.sha256 -notmatch '^[0-9a-f]{64}$') {
        throw "GTA5RP Launcher registry tree metadata is invalid"
    }
    $keys = @($Tree.keys)
    if ($keys.Count -lt 1 -or $keys.Count -gt 256) {
        throw "GTA5RP Launcher registry tree key count is invalid"
    }
    $nativeTree = New-Object IscsiReset.Gta5RpRegistryTreeSnapshot
    $nativeTree.RootName = $ExpectedRoot
    $canonicalKeys = @()
    $seenPaths = @{}
    $previousPath = $null
    $valueCount = 0
    $totalBytes = [int64]0
    foreach ($key in $keys) {
        $path = [string]$key.path
        if ($path.IndexOf([char]0) -ge 0 -or $path.Length -gt 4096 -or
            $seenPaths.ContainsKey($path)) {
            throw "GTA5RP Launcher registry key path is invalid"
        }
        if ($null -eq $previousPath) {
            if ($path -cne "") {
                throw "GTA5RP Launcher registry root key is missing"
            }
        } elseif ([StringComparer]::OrdinalIgnoreCase.Compare(
            [string]$previousPath, $path
        ) -ge 0) {
            throw "GTA5RP Launcher registry keys are not canonical"
        }
        $segments = @()
        if ($path -cne "") {
            $segments = @($path -split '\\')
            if ($segments.Count -gt 16 -or @($segments | Where-Object {
                [string]::IsNullOrEmpty([string]$_) -or
                ([string]$_).IndexOf([char]0) -ge 0
            }).Count -ne 0) {
                throw "GTA5RP Launcher registry key depth is invalid"
            }
            $parent = if ($segments.Count -eq 1) {
                ""
            } else {
                [string]::Join("\", $segments[0..($segments.Count - 2)])
            }
            if (-not $seenPaths.ContainsKey($parent)) {
                throw "GTA5RP Launcher registry key parent is missing"
            }
        }
        $seenPaths[$path] = $true
        $previousPath = $path
        $nativeKey = New-Object IscsiReset.Gta5RpRegistryKeySnapshot
        $nativeKey.RelativePath = $path
        $canonicalValues = @()
        $seenNames = @{}
        $previousName = $null
        foreach ($value in @($key.values)) {
            $name = [string]$value.name
            if ($name.IndexOf([char]0) -ge 0 -or $name.Length -gt 16383 -or
                $seenNames.ContainsKey($name)) {
                throw "GTA5RP Launcher registry value name is invalid"
            }
            if ($null -ne $previousName -and
                [StringComparer]::OrdinalIgnoreCase.Compare(
                    [string]$previousName, $name
                ) -ge 0) {
                throw "GTA5RP Launcher registry values are not canonical"
            }
            $type = [int64]$value.type
            if ($type -notin @(0, 1, 2, 3, 4, 5, 7, 11)) {
                throw "GTA5RP Launcher registry value type is unsupported"
            }
            try {
                $data = [Convert]::FromBase64String([string]$value.base64)
            } catch {
                throw "GTA5RP Launcher registry value data is not valid Base64"
            }
            if ([Convert]::ToBase64String($data) -cne [string]$value.base64) {
                throw "GTA5RP Launcher registry value data is not canonical Base64"
            }
            if ($data.Length -gt 4MB -or
                [int64]$value.length -ne [int64]$data.Length) {
                throw "GTA5RP Launcher registry value length is invalid"
            }
            $valueCount++
            $totalBytes += [int64]$data.Length
            if ($valueCount -gt 1024 -or $totalBytes -gt 16MB) {
                throw "GTA5RP Launcher registry tree exceeds its limits"
            }
            $nativeValue = New-Object IscsiReset.Gta5RpRegistryValueSnapshot
            $nativeValue.Name = $name
            $nativeValue.Type = [uint32]$type
            $nativeValue.Data = [byte[]]$data
            $nativeKey.Values.Add($nativeValue)
            $canonicalValues += [ordered]@{
                name = $name
                type = $type
                length = [int64]$data.Length
                base64 = [Convert]::ToBase64String($data)
            }
            $seenNames[$name] = $true
            $previousName = $name
        }
        $nativeTree.Keys.Add($nativeKey)
        $canonicalKeys += [ordered]@{
            path = $path
            values = $canonicalValues
        }
    }
    $nativeTree.ValueCount = $valueCount
    $nativeTree.TotalDataBytes = $totalBytes
    $canonical = [ordered]@{
        root = $ExpectedRoot
        keys = $canonicalKeys
    }
    $canonicalBytes = (New-Object Text.UTF8Encoding($false)).GetBytes(
        ($canonical | ConvertTo-Json -Depth 8 -Compress)
    )
    $sha = Get-EgsSha256Hex $canonicalBytes
    if ($sha -cne [string]$Tree.sha256) {
        throw "GTA5RP Launcher registry tree hash verification failed"
    }
    return [pscustomobject]@{
        Root = $ExpectedRoot
        NativeTree = $nativeTree
        Sha256 = $sha
        KeyCount = $keys.Count
        ValueCount = $valueCount
        TotalDataBytes = $totalBytes
    }
}

function Get-ClientGta5RpBundle {
    param(
        [Parameter(Mandatory = $true)]$ExpectedVolumes,
        [Parameter(Mandatory = $true)][string]$ConfigRevision
    )
    if (@($ExpectedVolumes).Count -eq 0) {
        throw "GTA5RP Launcher settings require at least one mounted volume"
    }
    $commonBytes = $null
    $commonSha = ""
    foreach ($volume in $ExpectedVolumes) {
        $root = Get-Gta5RpVolumeRoot -ExpectedVolume $volume
        $path = Join-Path $root ".iscsi-reset\gta5rp-launcher-settings.v1.json"
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "GTA5RP Launcher settings bundle is missing"
        }
        $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if ((([int]$item.Attributes -band [int][IO.FileAttributes]::ReparsePoint) -ne 0) -or
            [int64]$item.Length -lt 1 -or [int64]$item.Length -gt 32MB) {
            throw "GTA5RP Launcher settings bundle file is unsafe"
        }
        $bytes = [IO.File]::ReadAllBytes($path)
        $sha = Get-EgsSha256Hex $bytes
        if ($null -eq $commonBytes) {
            $commonBytes = $bytes
            $commonSha = $sha
        } elseif ($bytes.Length -ne $commonBytes.Length -or $sha -cne $commonSha) {
            throw "GTA5RP Launcher settings bundles do not match"
        }
    }
    try {
        $strictUtf8 = New-Object Text.UTF8Encoding($false, $true)
        $bundle = $strictUtf8.GetString($commonBytes) | ConvertFrom-Json
    } catch {
        throw "GTA5RP Launcher settings bundle is not valid UTF-8 JSON"
    }
    if ([int]$bundle.schema_version -ne 1 -or
        [string]$bundle.config_revision -cne $ConfigRevision) {
        throw "GTA5RP Launcher settings bundle metadata is invalid"
    }
    Initialize-Gta5RpRegistryNative
    $sourceTrees = @($bundle.registry_trees)
    if ($sourceTrees.Count -ne 2) {
        throw "GTA5RP Launcher settings bundle tree set is invalid"
    }
    $trees = @(
        ConvertFrom-ClientGta5RpRegistryTree -Tree $sourceTrees[0] `
            -ExpectedRoot "GTA5RPLauncher"
        ConvertFrom-ClientGta5RpRegistryTree -Tree $sourceTrees[1] `
            -ExpectedRoot "RAGE-MP"
    )
    $keyCount = [int](($trees | Measure-Object -Property KeyCount -Sum).Sum)
    $valueCount = [int](($trees | Measure-Object -Property ValueCount -Sum).Sum)
    $totalBytes = [int64](($trees | Measure-Object -Property TotalDataBytes -Sum).Sum)
    if ($keyCount -gt 256 -or $valueCount -gt 1024 -or $totalBytes -gt 16MB) {
        throw "GTA5RP Launcher registry snapshot exceeds its aggregate limits"
    }
    return [pscustomobject]@{
        Trees = $trees
        BundleSha256 = $commonSha
        KeyCount = $keyCount
        ValueCount = $valueCount
        TotalDataBytes = $totalBytes
    }
}

function Invoke-Gta5RpRegistryTransaction {
    param(
        [Parameter(Mandatory = $true)][string]$RootName,
        [Parameter(Mandatory = $true)]$Trees,
        [scriptblock]$BeforeCommit = $null
    )
    Initialize-Gta5RpRegistryNative
    $transaction = [IntPtr]::Zero
    $softwareKey = [IntPtr]::Zero
    $committed = $false
    try {
        foreach ($tree in $Trees) {
            [IscsiReset.Gta5RpRegistryNative]::AssertTreeHasNoLinks(
                $RootName,
                [string]$tree.Root
            )
        }
        $transaction = [IscsiReset.Gta5RpRegistryNative]::BeginTransaction()
        $softwareKey = [IscsiReset.Gta5RpRegistryNative]::OpenUserSoftwareTransacted(
            $RootName,
            $transaction
        )
        foreach ($tree in $Trees) {
            [IscsiReset.Gta5RpRegistryNative]::DeleteTreeTransacted(
                $softwareKey,
                [string]$tree.Root,
                $transaction
            )
        }
        foreach ($tree in $Trees) {
            [IscsiReset.Gta5RpRegistryNative]::WriteTreeTransacted(
                $softwareKey,
                $tree.NativeTree,
                $transaction
            )
        }
        foreach ($tree in $Trees) {
            $actual = [IscsiReset.Gta5RpRegistryNative]::CaptureTreeTransacted(
                $softwareKey,
                [string]$tree.Root,
                $transaction
            )
            $actualPayload = ConvertTo-Gta5RpRegistryTreePayload -Tree $actual
            if ([string]$actualPayload.Payload.sha256 -cne [string]$tree.Sha256) {
                throw "GTA5RP Launcher transacted registry verification failed"
            }
        }
        if ($null -ne $BeforeCommit) { & $BeforeCommit }
        [IscsiReset.Gta5RpRegistryNative]::CloseRegistryKey($softwareKey)
        $softwareKey = [IntPtr]::Zero
        [IscsiReset.Gta5RpRegistryNative]::CommitTransaction($transaction)
        $committed = $true
        foreach ($tree in $Trees) {
            $actual = [IscsiReset.Gta5RpRegistryNative]::CaptureTree(
                $RootName,
                [string]$tree.Root
            )
            $actualPayload = ConvertTo-Gta5RpRegistryTreePayload -Tree $actual
            if ([string]$actualPayload.Payload.sha256 -cne [string]$tree.Sha256) {
                throw "GTA5RP Launcher committed registry verification failed"
            }
        }
    } finally {
        if ($softwareKey -ne [IntPtr]::Zero) {
            [IscsiReset.Gta5RpRegistryNative]::CloseRegistryKey($softwareKey)
        }
        if (-not $committed -and $transaction -ne [IntPtr]::Zero) {
            [IscsiReset.Gta5RpRegistryNative]::RollbackTransaction($transaction)
        }
        if ($transaction -ne [IntPtr]::Zero) {
            [IscsiReset.Gta5RpRegistryNative]::CloseTransaction($transaction)
        }
    }
}

function Invoke-ClientGta5RpSettingsSync {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)]$ExpectedVolumes,
        [Parameter(Mandatory = $true)][string]$ConfigRevision
    )
    $bundle = Get-ClientGta5RpBundle -ExpectedVolumes $ExpectedVolumes `
        -ConfigRevision $ConfigRevision
    $hive = Open-Gta5RpUserHive -UserSid $Config.UserSid `
        -ProfilePath $Config.ProfilePath
    $failure = $null
    try {
        Invoke-Gta5RpRegistryTransaction -RootName $hive.RootName `
            -Trees $bundle.Trees
    } catch {
        $failure = $_
        throw
    } finally {
        try { Close-Gta5RpUserHive -Hive $hive } catch {
            if ($null -eq $failure) { throw }
        }
    }
    return [pscustomobject]@{
        BundleSha256 = $bundle.BundleSha256
        TreeCount = 2
        KeyCount = [int]$bundle.KeyCount
        ValueCount = [int]$bundle.ValueCount
        TotalDataBytes = [int64]$bundle.TotalDataBytes
    }
}

function Initialize-EgsZipSupport {
    try { Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop } catch { }
    try { Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop } catch { }
}

function ConvertTo-ClientEgsArchiveRelativePath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $candidate = $Path.Replace("\", "/")
    if ([string]::IsNullOrWhiteSpace($candidate) -or
        $candidate.StartsWith("/") -or $candidate.EndsWith("/") -or
        $candidate.Contains(":") -or $candidate.Contains("//")) {
        throw "Epic Games aggressive payload contains an unsafe relative path"
    }
    foreach ($segment in @($candidate -split "/")) {
        if ([string]::IsNullOrWhiteSpace($segment) -or $segment -in @(".", "..")) {
            throw "Epic Games aggressive payload contains an unsafe relative path"
        }
    }
    return $candidate
}

function Join-ClientEgsRelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )
    $safe = ConvertTo-ClientEgsArchiveRelativePath $RelativePath
    $result = $Root
    foreach ($segment in @($safe -split "/")) {
        $result = Join-Path $result $segment
    }
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd([char[]]@(92, 47))
    $fullResult = [IO.Path]::GetFullPath($result)
    $separator = [IO.Path]::DirectorySeparatorChar
    if (-not $fullResult.StartsWith(
        $fullRoot + $separator,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Epic Games aggressive payload escapes its staging root"
    }
    return $fullResult
}

function Read-ClientEgsAggressiveIndex {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$ArchiveMetadata,
        [int]$MaximumFileCount = 100000,
        [Int64]$MaximumTotalBytes = 1GB,
        [Int64]$MaximumFileBytes = 512MB
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Epic Games aggressive index is missing"
    }
    $indexBytes = [IO.File]::ReadAllBytes($Path)
    if ([Int64]$indexBytes.Length -ne [Int64]$ArchiveMetadata.index_length -or
        (Get-EgsSha256Hex $indexBytes) -ne [string]$ArchiveMetadata.index_sha256) {
        throw "Epic Games aggressive index hash verification failed"
    }
    try { $index = ConvertFrom-EgsJsonBytes -Bytes $indexBytes } catch {
        throw "Epic Games aggressive index is not valid JSON"
    }
    if ([int]$index.schema_version -ne 2 -or
        [int]$index.file_count -ne @($index.files).Count -or
        [int]$index.file_count -gt $MaximumFileCount -or
        [Int64]$index.total_bytes -gt $MaximumTotalBytes -or
        [Int64]$index.total_bytes -ne [Int64]$ArchiveMetadata.total_bytes -or
        [int]$index.file_count -ne [int]$ArchiveMetadata.file_count) {
        throw "Epic Games aggressive index limits or counts are invalid"
    }

    $seen = @{}
    $totalBytes = [Int64]0
    $files = @()
    foreach ($entry in @($index.files)) {
        $relative = ConvertTo-ClientEgsArchiveRelativePath ([string]$entry.relative_path)
        if (-not ($relative.StartsWith(
            "EpicGamesLauncher/Data/", [StringComparison]::Ordinal
        ) -or $relative.StartsWith(
            "EpicOnlineServicesShared/InstallHelper/InstalledItems/",
            [StringComparison]::Ordinal
        ) -or $relative -ceq "UnrealEngineLauncher/LauncherInstalled.dat")) {
            throw "Epic Games aggressive index contains an unsupported file root"
        }
        if ($seen.ContainsKey($relative)) {
            throw "Epic Games aggressive index contains a duplicate relative path"
        }
        $seen[$relative] = $true
        $length = [Int64]$entry.length
        if ($length -lt 0 -or $length -gt $MaximumFileBytes -or
            [string]$entry.sha256 -notmatch "^[0-9A-Fa-f]{64}$" -or
            ([int]$entry.attributes -band [int][IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Epic Games aggressive index contains invalid file metadata"
        }
        try {
            [DateTime]::Parse(
                [string]$entry.creation_time_utc,
                [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::RoundtripKind
            ) | Out-Null
            [DateTime]::Parse(
                [string]$entry.last_write_time_utc,
                [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::RoundtripKind
            ) | Out-Null
        } catch { throw "Epic Games aggressive index contains invalid timestamps" }
        $totalBytes += $length
        if ($totalBytes -gt $MaximumTotalBytes) {
            throw "Epic Games aggressive index exceeds the total size safety limit"
        }
        $files += [pscustomobject]@{
            RelativePath = $relative
            Length = $length
            Sha256 = ([string]$entry.sha256).ToLowerInvariant()
            Attributes = [int]$entry.attributes
            CreationTimeUtc = [string]$entry.creation_time_utc
            LastWriteTimeUtc = [string]$entry.last_write_time_utc
        }
    }
    if ($totalBytes -ne [Int64]$index.total_bytes -or
        @($files | Where-Object {
            $_.RelativePath -ceq "UnrealEngineLauncher/LauncherInstalled.dat"
        }).Count -ne 1) {
        throw "Epic Games aggressive index total or LauncherInstalled.dat is invalid"
    }
    if (@($files | Where-Object {
        $_.RelativePath.StartsWith(
            "EpicOnlineServicesShared/InstallHelper/InstalledItems/",
            [StringComparison]::Ordinal
        )
    }).Count -eq 0) {
        throw "Epic Games aggressive shared installation database is empty"
    }

    $directories = @()
    foreach ($entry in @($index.directories)) {
        $relative = ConvertTo-ClientEgsArchiveRelativePath ([string]$entry.relative_path)
        if (-not ($relative -ceq "EpicGamesLauncher" -or
            $relative -ceq "EpicGamesLauncher/Data" -or
            $relative.StartsWith("EpicGamesLauncher/Data/", [StringComparison]::Ordinal) -or
            $relative -ceq "UnrealEngineLauncher" -or
            $relative -ceq "EpicOnlineServicesShared" -or
            $relative -ceq "EpicOnlineServicesShared/InstallHelper" -or
            $relative -ceq "EpicOnlineServicesShared/InstallHelper/InstalledItems" -or
            $relative.StartsWith(
                "EpicOnlineServicesShared/InstallHelper/InstalledItems/",
                [StringComparison]::Ordinal
            ))) {
            throw "Epic Games aggressive index contains an unsupported directory root"
        }
        if ($seen.ContainsKey($relative)) {
            throw "Epic Games aggressive index contains a file/directory path collision"
        }
        $seen[$relative] = $true
        if (([int]$entry.attributes -band [int][IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Epic Games aggressive index contains a reparse directory"
        }
        try {
            [DateTime]::Parse(
                [string]$entry.creation_time_utc,
                [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::RoundtripKind
            ) | Out-Null
            [DateTime]::Parse(
                [string]$entry.last_write_time_utc,
                [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::RoundtripKind
            ) | Out-Null
        } catch { throw "Epic Games aggressive index contains invalid directory timestamps" }
        $directories += [pscustomobject]@{
            RelativePath = $relative
            Attributes = [int]$entry.attributes
            CreationTimeUtc = [string]$entry.creation_time_utc
            LastWriteTimeUtc = [string]$entry.last_write_time_utc
        }
    }
    foreach ($required in @(
        "EpicGamesLauncher", "EpicGamesLauncher/Data", "UnrealEngineLauncher",
        "EpicOnlineServicesShared", "EpicOnlineServicesShared/InstallHelper",
        "EpicOnlineServicesShared/InstallHelper/InstalledItems"
    )) {
        if (@($directories | Where-Object { $_.RelativePath -ceq $required }).Count -ne 1) {
            throw "Epic Games aggressive index is missing a required directory"
        }
    }
    return [pscustomobject]@{
        Bytes = $indexBytes
        Files = $files
        Directories = $directories
        FileCount = $files.Count
        TotalBytes = $totalBytes
        TreeSha256 = Get-EgsSha256Hex $indexBytes
    }
}

function Expand-ClientEgsAggressiveArchive {
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)]$ArchiveMetadata,
        [Parameter(Mandatory = $true)]$IndexData,
        [Parameter(Mandatory = $true)][string]$StagePath
    )
    Initialize-EgsZipSupport
    if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf) -or
        [Int64](Get-Item -LiteralPath $ArchivePath).Length -ne
            [Int64]$ArchiveMetadata.archive_length -or
        (Get-EgsFileSha256Hex -Path $ArchivePath) -ne
            [string]$ArchiveMetadata.archive_sha256) {
        throw "Epic Games aggressive archive hash verification failed"
    }
    if (Test-Path -LiteralPath $StagePath) {
        Remove-Item -LiteralPath $StagePath -Recurse -Force
    }
    New-Item -ItemType Directory -Path $StagePath -Force | Out-Null
    try {
        foreach ($directory in @($IndexData.Directories | Sort-Object {
            $_.RelativePath.Length
        })) {
            New-Item -ItemType Directory -Path (
                Join-ClientEgsRelativePath -Root $StagePath `
                    -RelativePath $directory.RelativePath
            ) -Force | Out-Null
        }
        $zip = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
        try {
            $zipFiles = @{}
            $zipDirectories = @{}
            foreach ($entry in @($zip.Entries)) {
                $name = $entry.FullName
                if ($name.EndsWith("/")) {
                    $directoryName = $name.Substring(0, $name.Length - 1)
                    $safeDirectory = ConvertTo-ClientEgsArchiveRelativePath $directoryName
                    if ($zipDirectories.ContainsKey($safeDirectory)) {
                        throw "Epic Games aggressive archive contains duplicate directories"
                    }
                    $zipDirectories[$safeDirectory] = $true
                    continue
                }
                $safe = ConvertTo-ClientEgsArchiveRelativePath $name
                if ($zipFiles.ContainsKey($safe)) {
                    throw "Epic Games aggressive archive contains duplicate entries"
                }
                $zipFiles[$safe] = $entry
            }
            if ($zipFiles.Count -ne $IndexData.FileCount) {
                throw "Epic Games aggressive archive contains an unexpected file set"
            }
            if ($zipDirectories.Count -ne @($IndexData.Directories).Count) {
                throw "Epic Games aggressive archive contains an unexpected directory set"
            }
            foreach ($directory in $IndexData.Directories) {
                if (-not $zipDirectories.ContainsKey($directory.RelativePath)) {
                    throw "Epic Games aggressive archive is missing an indexed directory"
                }
            }
            foreach ($expected in $IndexData.Files) {
                if (-not $zipFiles.ContainsKey($expected.RelativePath)) {
                    throw "Epic Games aggressive archive is missing an indexed file"
                }
                $entry = $zipFiles[$expected.RelativePath]
                if ([Int64]$entry.Length -ne [Int64]$expected.Length) {
                    throw "Epic Games aggressive archive entry length is invalid"
                }
                $target = Join-ClientEgsRelativePath -Root $StagePath `
                    -RelativePath $expected.RelativePath
                $parent = Split-Path $target -Parent
                if (-not (Test-Path -LiteralPath $parent)) {
                    New-Item -ItemType Directory -Path $parent -Force | Out-Null
                }
                $input = $entry.Open()
                $output = New-Object IO.FileStream(
                    $target,
                    [IO.FileMode]::CreateNew,
                    [IO.FileAccess]::Write,
                    [IO.FileShare]::None
                )
                try { $input.CopyTo($output) } finally {
                    $output.Dispose()
                    $input.Dispose()
                }
                if ((Get-EgsFileSha256Hex -Path $target) -ne $expected.Sha256) {
                    throw "Epic Games aggressive extracted file hash is invalid"
                }
            }
        } finally {
            $zip.Dispose()
        }
    } catch {
        Remove-Item -LiteralPath $StagePath -Recurse -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Assert-ClientEgsItem {
    param(
        [Parameter(Mandatory = $true)]$Item,
        [Parameter(Mandatory = $true)]$Entry,
        [Parameter(Mandatory = $true)][string]$VolumeRoot
    )
    $appName = Get-RequiredEgsString -Item $Item -Name "AppName"
    $guid = Get-RequiredEgsString -Item $Item -Name "InstallationGuid"
    if (-not (Test-EgsInstallationId $guid)) {
        throw "$appName has an invalid Epic installation identifier"
    }
    if ($appName -ne [string]$Entry.app_name -or
        $guid -ne [string]$Entry.installation_guid) {
        throw "Epic Games bundle entry identity does not match its payload"
    }
    $appVersion = Get-RequiredEgsString -Item $Item -Name "AppVersionString"
    if ($Item.PSObject.Properties.Name -notcontains "InstallTags") {
        throw "$appName manifest has no InstallTags"
    }

    $installLocation = ConvertTo-EgsCanonicalPath (
        Get-RequiredEgsString -Item $Item -Name "InstallLocation"
    )
    if (-not (Test-EgsPathWithinRoot -Path $installLocation -RootPath $VolumeRoot)) {
        throw "$appName install path does not belong to its client volume"
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
    if ([string]$Entry.binary_manifest_sha256 -notmatch "^[0-9A-Fa-f]{64}$" -or
        (Get-EgsSha256Hex ([IO.File]::ReadAllBytes($binaryManifest))) -ne
            ([string]$Entry.binary_manifest_sha256).ToLowerInvariant()) {
        throw "$appName .egstore binary manifest hash does not match the bundle"
    }
    $componentExists = Test-Path -LiteralPath $component -PathType Leaf
    $expectedComponentSha = [string]$Entry.mancpn_sha256
    if ($componentExists -ne (-not [string]::IsNullOrWhiteSpace($expectedComponentSha))) {
        throw "$appName .mancpn presence does not match the bundle"
    }
    if ($componentExists) {
        $componentData = Get-Content -LiteralPath $component -Raw | ConvertFrom-Json
        if ([string]$componentData.AppName -ne $appName) {
            throw "$appName .mancpn AppName does not match"
        }
        if ($expectedComponentSha -notmatch "^[0-9A-Fa-f]{64}$" -or
            (Get-EgsSha256Hex ([IO.File]::ReadAllBytes($component))) -ne
                $expectedComponentSha.ToLowerInvariant()) {
            throw "$appName .mancpn hash does not match the bundle"
        }
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
    $validWarningCodes = @(
        "item_incomplete", "item_needs_validation", "bps_nonempty", "pending_nonempty"
    )
    foreach ($warning in @($Entry.state_warnings)) {
        if ([string]$warning -notin $validWarningCodes) {
            throw "$appName bundle has an invalid state warning"
        }
    }
    $actualWarnings = @(Get-ClientEgsStateWarnings -Item $Item `
        -InstallLocation $installLocation)
    $actualWarningKey = (@($actualWarnings) | Sort-Object) -join ","
    $bundleWarningKey = (@($Entry.state_warnings) | Sort-Object) -join ","
    if ($actualWarningKey -cne $bundleWarningKey) {
        throw "$appName state warnings do not match the bundle"
    }

    $launcherRegistration = $null
    if ($null -ne $Entry.launcher_registration) {
        $registration = $Entry.launcher_registration
        $requiredNames = @(
            "install_location", "namespace_id", "item_id", "artifact_id", "app_version",
            "app_name"
        )
        $actualNames = @($registration.PSObject.Properties.Name | Sort-Object)
        if (($actualNames -join ",") -cne (($requiredNames | Sort-Object) -join ",")) {
            throw "$appName launcher registration contains unsupported fields"
        }
        foreach ($name in $requiredNames) {
            if ([string]::IsNullOrWhiteSpace([string]$registration.$name)) {
                throw "$appName launcher registration has an empty $name"
            }
        }
        $registrationLocation = ConvertTo-EgsCanonicalPath (
            [string]$registration.install_location
        )
        if ([string]$registration.app_name -ne $appName -or
            -not $registrationLocation.Equals(
                $installLocation, [StringComparison]::OrdinalIgnoreCase
            ) -or
            -not [string]::Equals(
                [string]$registration.app_version,
                $appVersion,
                [StringComparison]::Ordinal
            )) {
            throw "$appName launcher registration does not match its manifest"
        }
        $launcherRegistration = [pscustomobject]@{
            InstallLocation = $registrationLocation
            NamespaceId = [string]$registration.namespace_id
            ItemId = [string]$registration.item_id
            ArtifactId = [string]$registration.artifact_id
            AppVersion = [string]$registration.app_version
            AppName = [string]$registration.app_name
        }
    }
    return [pscustomobject]@{
        AppName = $appName
        AppVersion = $appVersion
        InstallationGuid = $guid
        InstallLocation = $installLocation
        LauncherRegistration = $launcherRegistration
        StateWarnings = $actualWarnings
    }
}

function Read-ClientEgsBundle {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ConfigRevision,
        [Parameter(Mandatory = $true)][string]$VolumeName,
        [Parameter(Mandatory = $true)][string]$VolumeRoot
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Epic Games bundle is missing for volume $VolumeName"
    }
    $bundle = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ([int]$bundle.schema_version -ne 2 -or
        [string]$bundle.config_revision -ne $ConfigRevision -or
        [string]$bundle.volume_name -ne $VolumeName -or
        $bundle.PSObject.Properties.Name -notcontains "manifests") {
        throw "Epic Games bundle does not match volume $VolumeName and current config revision"
    }

    $result = @()
    foreach ($entry in @($bundle.manifests)) {
        try {
            $bytes = [Convert]::FromBase64String([string]$entry.payload_base64)
        } catch {
            throw "Epic Games bundle payload is not valid Base64 for $($entry.app_name)"
        }
        $sha = Get-EgsSha256Hex $bytes
        if ($sha -ne ([string]$entry.sha256).ToLowerInvariant()) {
            throw "Epic Games bundle hash verification failed for $($entry.app_name)"
        }
        try {
            $item = ConvertFrom-EgsJsonBytes -Bytes $bytes
        } catch {
            throw "Epic Games bundle payload is not valid JSON for $($entry.app_name)"
        }
        $identity = Assert-ClientEgsItem -Item $item -Entry $entry -VolumeRoot $VolumeRoot
        $result += [pscustomobject]@{
            AppName = $identity.AppName
            AppVersion = $identity.AppVersion
            InstallationGuid = $identity.InstallationGuid
            InstallLocation = $identity.InstallLocation
            Sha256 = $sha
            Bytes = $bytes
            TargetFileName = "$($identity.InstallationGuid).item"
            LauncherRegistration = $identity.LauncherRegistration
            StateWarnings = @($identity.StateWarnings)
        }
    }
    return $result
}

function Test-ClientEgsOrdinalNameMember {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Name,
        [Parameter(Mandatory = $true)]$Names
    )
    foreach ($candidate in @($Names)) {
        if ([string]$candidate -ceq $Name) { return $true }
    }
    return $false
}

function Assert-ClientEgsExactVolumeNameSet {
    param(
        [Parameter(Mandatory = $true)]$PublisherNames,
        [Parameter(Mandatory = $true)]$ClientNames
    )
    $publisher = [string[]]@($PublisherNames | ForEach-Object { [string]$_ })
    $client = [string[]]@($ClientNames | ForEach-Object { [string]$_ })
    $publisherCount = $publisher.Count
    $clientCount = $client.Count
    $invalid = $publisherCount -eq 0 -or $clientCount -eq 0
    foreach ($name in @($publisher) + @($client)) {
        if ([string]::IsNullOrWhiteSpace($name)) { $invalid = $true }
    }
    [Array]::Sort($publisher, [StringComparer]::Ordinal)
    [Array]::Sort($client, [StringComparer]::Ordinal)
    for ($index = 1; $index -lt $publisher.Count; $index++) {
        if ($publisher[$index - 1] -ceq $publisher[$index]) { $invalid = $true }
    }
    for ($index = 1; $index -lt $client.Count; $index++) {
        if ($client[$index - 1] -ceq $client[$index]) { $invalid = $true }
    }
    if (-not $invalid -and $publisherCount -eq $clientCount) {
        for ($index = 0; $index -lt $publisherCount; $index++) {
            if ($publisher[$index] -cne $client[$index]) {
                $invalid = $true
                break
            }
        }
    } else {
        $invalid = $true
    }
    if ($invalid) {
        throw ("Epic Games aggressive iSCSI volume set mismatch " +
            "(publisher_count=$publisherCount, client_count=$clientCount)")
    }
}

function Resolve-ClientEgsAggressiveAnchorRoot {
    param(
        [Parameter(Mandatory = $true)][string]$AnchorVolume,
        [Parameter(Mandatory = $true)]$VolumeRoots
    )
    $matches = @($VolumeRoots | Where-Object {
        [string]$_.Name -ceq $AnchorVolume
    })
    if ($matches.Count -ne 1 -or
        [string]::IsNullOrWhiteSpace([string]$matches[0].Root)) {
        throw "Epic Games aggressive anchor is not a mounted iSCSI volume"
    }
    return [string]$matches[0].Root
}

function Read-ClientEgsAggressiveBundles {
    param(
        [Parameter(Mandatory = $true)]$ExpectedVolumes,
        [Parameter(Mandatory = $true)][string]$ConfigRevision
    )
    $expectedNames = @($ExpectedVolumes | ForEach-Object { [string]$_.name })
    Assert-ClientEgsExactVolumeNameSet -PublisherNames $expectedNames `
        -ClientNames $expectedNames
    $desired = @()
    $archiveMetadata = $null
    $roots = @()
    foreach ($volume in $ExpectedVolumes) {
        $volumeName = [string]$volume.name
        $letter = ([string]$volume.drive_letter).Trim().ToUpperInvariant()
        if ($letter -notmatch "^[A-Z]$") {
            throw "Invalid drive letter for Epic Games volume $volumeName"
        }
        $root = "$letter`:\"
        $roots += [pscustomobject]@{ Name = $volumeName; Root = $root }
        $bundlePath = Join-Path $root ".iscsi-reset\egs-manifests.v4.json"
        if (-not (Test-Path -LiteralPath $bundlePath -PathType Leaf)) {
            if (Test-Path -LiteralPath (Join-Path $root `
                ".iscsi-reset\egs-manifests.v3.json") -PathType Leaf) {
                throw "Epic Games bundle v3 is unsupported in aggressive mode; create a v4 release"
            }
            if (Test-Path -LiteralPath (Join-Path $root `
                ".iscsi-reset\egs-manifests.v2.json") -PathType Leaf) {
                throw "Epic Games bundle v2 is unsupported in aggressive mode; create a v4 release"
            }
            throw "Epic Games aggressive bundle is missing for volume $volumeName"
        }
        $bundle = Get-Content -LiteralPath $bundlePath -Raw | ConvertFrom-Json
        if ([int]$bundle.schema_version -ne 4 -or
            [string]$bundle.config_revision -ne $ConfigRevision -or
            [string]$bundle.volume_name -cne $volumeName -or
            $bundle.PSObject.Properties.Name -notcontains "manifests" -or
            $null -eq $bundle.archive) {
            throw "Epic Games aggressive bundle does not match volume $volumeName"
        }
        Assert-ClientEgsExactVolumeNameSet `
            -PublisherNames @($bundle.publisher_volume_names) `
            -ClientNames $expectedNames
        $metadata = $bundle.archive
        foreach ($name in @(
            "anchor_volume", "archive_file_name", "archive_sha256", "archive_length",
            "index_file_name", "index_sha256", "index_length", "tree_sha256",
            "file_count", "total_bytes"
        )) {
            if ($metadata.PSObject.Properties.Name -notcontains $name) {
                throw "Epic Games aggressive archive metadata is incomplete"
            }
        }
        if (-not (Test-ClientEgsOrdinalNameMember `
            -Name ([string]$metadata.anchor_volume) -Names $expectedNames) -or
            [string]$metadata.archive_file_name -cne "egs-state.v4.zip" -or
            [string]$metadata.index_file_name -cne "egs-state.v4.index.json" -or
            [string]$metadata.archive_sha256 -notmatch "^[0-9A-Fa-f]{64}$" -or
            [string]$metadata.index_sha256 -notmatch "^[0-9A-Fa-f]{64}$" -or
            [string]$metadata.tree_sha256 -notmatch "^[0-9A-Fa-f]{64}$" -or
            [Int64]$metadata.archive_length -lt 0 -or
            [Int64]$metadata.archive_length -gt 1GB -or
            [Int64]$metadata.index_length -lt 1 -or
            [Int64]$metadata.index_length -gt 128MB -or
            [int]$metadata.file_count -lt 1 -or
            [int]$metadata.file_count -gt 100000 -or
            [Int64]$metadata.total_bytes -lt 0 -or
            [Int64]$metadata.total_bytes -gt 1GB) {
            throw "Epic Games aggressive archive metadata is invalid"
        }
        $metadataKey = @(
            [string]$metadata.anchor_volume,
            [string]$metadata.archive_file_name,
            ([string]$metadata.archive_sha256).ToLowerInvariant(),
            [string][Int64]$metadata.archive_length,
            [string]$metadata.index_file_name,
            ([string]$metadata.index_sha256).ToLowerInvariant(),
            [string][Int64]$metadata.index_length,
            ([string]$metadata.tree_sha256).ToLowerInvariant(),
            [string][int]$metadata.file_count,
            [string][Int64]$metadata.total_bytes
        ) -join "`n"
        if ($null -eq $archiveMetadata) {
            $archiveMetadata = [pscustomobject]@{
                anchor_volume = [string]$metadata.anchor_volume
                archive_file_name = [string]$metadata.archive_file_name
                archive_sha256 = ([string]$metadata.archive_sha256).ToLowerInvariant()
                archive_length = [Int64]$metadata.archive_length
                index_file_name = [string]$metadata.index_file_name
                index_sha256 = ([string]$metadata.index_sha256).ToLowerInvariant()
                index_length = [Int64]$metadata.index_length
                tree_sha256 = ([string]$metadata.tree_sha256).ToLowerInvariant()
                file_count = [int]$metadata.file_count
                total_bytes = [Int64]$metadata.total_bytes
                Key = $metadataKey
            }
        } elseif ([string]$archiveMetadata.Key -cne $metadataKey) {
            throw "Epic Games aggressive bundles disagree about the archive"
        }

        foreach ($entry in @($bundle.manifests)) {
            try { $bytes = [Convert]::FromBase64String([string]$entry.payload_base64) } catch {
                throw "Epic Games aggressive bundle payload is not valid Base64"
            }
            $sha = Get-EgsSha256Hex $bytes
            if ($sha -ne ([string]$entry.sha256).ToLowerInvariant()) {
                throw "Epic Games aggressive bundle payload hash verification failed"
            }
            try { $item = ConvertFrom-EgsJsonBytes -Bytes $bytes } catch {
                throw "Epic Games aggressive bundle payload is not valid JSON"
            }
            $identity = Assert-ClientEgsItem -Item $item -Entry $entry -VolumeRoot $root
            $desired += [pscustomobject]@{
                AppName = $identity.AppName
                AppVersion = $identity.AppVersion
                InstallationGuid = $identity.InstallationGuid
                InstallLocation = $identity.InstallLocation
                Sha256 = $sha
                Bytes = $bytes
                TargetFileName = "$($identity.InstallationGuid).item"
                LauncherRegistration = $identity.LauncherRegistration
                StateWarnings = @($identity.StateWarnings)
            }
        }
    }
    $seenApps = @{}
    $seenFiles = @{}
    foreach ($entry in $desired) {
        if ($seenApps.ContainsKey($entry.AppName) -or
            $seenFiles.ContainsKey($entry.TargetFileName)) {
            throw "Epic Games aggressive inventory contains duplicate game identity"
        }
        $seenApps[$entry.AppName] = $true
        $seenFiles[$entry.TargetFileName] = $true
    }
    $anchorRoot = Resolve-ClientEgsAggressiveAnchorRoot `
        -AnchorVolume ([string]$archiveMetadata.anchor_volume) -VolumeRoots $roots
    return [pscustomobject]@{
        Desired = $desired
        ArchiveMetadata = $archiveMetadata
        AnchorRoot = $anchorRoot
        ArchivePath = Join-Path $anchorRoot `
            ".iscsi-reset\$($archiveMetadata.archive_file_name)"
        IndexPath = Join-Path $anchorRoot `
            ".iscsi-reset\$($archiveMetadata.index_file_name)"
    }
}

function Read-ExistingEgsManifests {
    param([Parameter(Mandatory = $true)][string]$ManifestDirectory)
    if (-not (Test-Path -LiteralPath $ManifestDirectory -PathType Container)) { return @() }
    $result = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $ManifestDirectory -Filter "*.item" -File)) {
        $bytes = [IO.File]::ReadAllBytes($file.FullName)
        try {
            $item = ConvertFrom-EgsJsonBytes -Bytes $bytes
        } catch {
            throw "Existing Epic Games manifest is not valid JSON: $($file.FullName)"
        }
        $result += [pscustomobject]@{
            AppName = Get-RequiredEgsString -Item $item -Name "AppName"
            InstallationGuid = Get-RequiredEgsString -Item $item -Name "InstallationGuid"
            InstallLocation = ConvertTo-EgsCanonicalPath (
                Get-RequiredEgsString -Item $item -Name "InstallLocation"
            )
            Sha256 = Get-EgsSha256Hex $bytes
            FileName = $file.Name
        }
    }
    return $result
}

function Read-ClientEgsManagedState {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ schema_version = 1; manifests = @() }
    }
    $state = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ([int]$state.schema_version -ne 1 -or
        $state.PSObject.Properties.Name -notcontains "manifests") {
        throw "Epic Games managed state is invalid: $Path"
    }
    $seen = @{}
    foreach ($entry in @($state.manifests)) {
        $appName = [string]$entry.app_name
        $guid = [string]$entry.installation_guid
        $sha256 = [string]$entry.sha256
        if ([string]::IsNullOrWhiteSpace($appName) -or $seen.ContainsKey($appName) -or
            -not (Test-EgsInstallationId $guid) -or $sha256 -notmatch "^[0-9A-Fa-f]{64}$") {
            throw "Epic Games managed state contains an invalid or duplicate AppName"
        }
        $seen[$appName] = $true
        ConvertTo-EgsCanonicalPath ([string]$entry.install_location) | Out-Null
    }
    return $state
}

function New-ClientEgsSyncPlan {
    param(
        [Parameter(Mandatory = $true)]$Desired,
        [Parameter(Mandatory = $true)]$Existing,
        [Parameter(Mandatory = $true)]$ManagedState
    )
    $desiredByApp = @{}
    $desiredFiles = @{}
    foreach ($entry in $Desired) {
        if ($desiredByApp.ContainsKey($entry.AppName)) {
            throw "Duplicate Epic Games AppName across client volumes: $($entry.AppName)"
        }
        if ($desiredFiles.ContainsKey($entry.TargetFileName)) {
            throw "Duplicate Epic Games InstallationGuid across client volumes"
        }
        $desiredByApp[$entry.AppName] = $entry
        $desiredFiles[$entry.TargetFileName] = $true
    }
    $managedByApp = @{}
    foreach ($entry in @($ManagedState.manifests)) {
        $managedByApp[[string]$entry.app_name] = $entry
    }

    $affected = @{}
    $remove = @{}
    $displaced = @{}
    $adoptedApps = @{}
    foreach ($desiredEntry in $Desired) {
        $sameName = @($Existing | Where-Object { $_.AppName -eq $desiredEntry.AppName })
        $sameTarget = @($Existing | Where-Object {
            $_.FileName -eq $desiredEntry.TargetFileName
        })
        foreach ($entry in $sameTarget) {
            if ($entry.AppName -ne $desiredEntry.AppName) {
                throw "Epic target .item filename belongs to another local application"
            }
        }
        if (-not $managedByApp.ContainsKey($desiredEntry.AppName)) {
            if ($sameName.Count -gt 0) {
                $adoptedApps[$desiredEntry.AppName] = $true
                foreach ($entry in $sameName) {
                    $affected[$entry.FileName] = $true
                    $displaced[$entry.FileName] = $true
                    if ($entry.FileName -ne $desiredEntry.TargetFileName) {
                        $remove[$entry.FileName] = $true
                    }
                }
            }
        } else {
            $managedEntry = $managedByApp[$desiredEntry.AppName]
            $managedFileName = "$([string]$managedEntry.installation_guid).item"
            $managedExisting = @($Existing | Where-Object { $_.FileName -eq $managedFileName })
            if ($managedExisting.Count -gt 1) {
                throw "Previously managed Epic manifest is ambiguous: $($desiredEntry.AppName)"
            }
            if ($managedExisting.Count -eq 1) {
                $managedLocation = ConvertTo-EgsCanonicalPath (
                    [string]$managedEntry.install_location
                )
                if ($managedExisting[0].AppName -ne $desiredEntry.AppName -or
                    $managedExisting[0].InstallationGuid -ne
                        [string]$managedEntry.installation_guid -or
                    -not $managedExisting[0].InstallLocation.Equals(
                        $managedLocation, [StringComparison]::OrdinalIgnoreCase
                    )) {
                    throw "Previously managed Epic manifest identity changed: $($desiredEntry.AppName)"
                }
                $affected[$managedFileName] = $true
                if ($managedFileName -ne $desiredEntry.TargetFileName) {
                    $remove[$managedFileName] = $true
                }
            }
            $unexpectedSameName = @($sameName | Where-Object {
                $_.FileName -ne $managedFileName
            })
            foreach ($entry in $unexpectedSameName) {
                $affected[$entry.FileName] = $true
                $displaced[$entry.FileName] = $true
                if ($entry.FileName -ne $desiredEntry.TargetFileName) {
                    $remove[$entry.FileName] = $true
                }
            }
        }
        $affected[$desiredEntry.TargetFileName] = $true
    }

    foreach ($appName in @($managedByApp.Keys)) {
        if ($desiredByApp.ContainsKey($appName)) { continue }
        $managedEntry = $managedByApp[$appName]
        $managedFileName = "$([string]$managedEntry.installation_guid).item"
        $managedExisting = @($Existing | Where-Object { $_.FileName -eq $managedFileName })
        if ($managedExisting.Count -gt 1) {
            throw "Previously managed Epic manifest is ambiguous: $appName"
        }
        foreach ($entry in $managedExisting) {
            $managedLocation = ConvertTo-EgsCanonicalPath ([string]$managedEntry.install_location)
            if ($entry.AppName -ne $appName -or
                $entry.InstallationGuid -ne [string]$managedEntry.installation_guid -or
                -not $entry.InstallLocation.Equals(
                    $managedLocation, [StringComparison]::OrdinalIgnoreCase
                )) {
                throw "Previously managed Epic manifest identity changed: $appName"
            }
            $affected[$managedFileName] = $true
            $remove[$managedFileName] = $true
        }
    }

    return [pscustomobject]@{
        Desired = @($Desired | Sort-Object AppName)
        PreviouslyManagedAppNames = @($managedByApp.Keys)
        AffectedFileNames = @($affected.Keys | Sort-Object)
        RemoveFileNames = @($remove.Keys | Sort-Object)
        DisplacedFileNames = @($displaced.Keys | Sort-Object)
        AdoptedAppNames = @($adoptedApps.Keys | Sort-Object)
    }
}

function Test-ClientEgsLauncherEntryMatches {
    param(
        [Parameter(Mandatory = $true)]$Entry,
        [Parameter(Mandatory = $true)]$Desired
    )
    if ($Entry.PSObject.Properties.Name -notcontains "InstallLocation" -or
        $Entry.PSObject.Properties.Name -notcontains "AppVersion") {
        return $false
    }
    try {
        $location = ConvertTo-EgsCanonicalPath ([string]$Entry.InstallLocation)
    } catch {
        return $false
    }
    return $location.Equals(
        [string]$Desired.InstallLocation,
        [StringComparison]::OrdinalIgnoreCase
    ) -and [string]::Equals(
        [string]$Entry.AppVersion,
        [string]$Desired.AppVersion,
        [StringComparison]::Ordinal
    )
}

function Test-ClientEgsLauncherEntryEqualsRegistration {
    param(
        [Parameter(Mandatory = $true)]$Entry,
        [Parameter(Mandatory = $true)]$Registration
    )
    $requiredNames = @(
        "InstallLocation", "NamespaceId", "ItemId", "ArtifactId", "AppVersion", "AppName"
    )
    $actualNames = @($Entry.PSObject.Properties.Name | Sort-Object)
    if (($actualNames -join ",") -cne (($requiredNames | Sort-Object) -join ",")) {
        return $false
    }
    try {
        $location = ConvertTo-EgsCanonicalPath ([string]$Entry.InstallLocation)
    } catch {
        return $false
    }
    return $location.Equals(
        [string]$Registration.InstallLocation,
        [StringComparison]::OrdinalIgnoreCase
    ) -and [string]::Equals(
        [string]$Entry.NamespaceId,
        [string]$Registration.NamespaceId,
        [StringComparison]::Ordinal
    ) -and [string]::Equals(
        [string]$Entry.ItemId,
        [string]$Registration.ItemId,
        [StringComparison]::Ordinal
    ) -and [string]::Equals(
        [string]$Entry.ArtifactId,
        [string]$Registration.ArtifactId,
        [StringComparison]::Ordinal
    ) -and [string]::Equals(
        [string]$Entry.AppVersion,
        [string]$Registration.AppVersion,
        [StringComparison]::Ordinal
    ) -and [string]::Equals(
        [string]$Entry.AppName,
        [string]$Registration.AppName,
        [StringComparison]::Ordinal
    )
}

function New-ClientEgsLauncherEntry {
    param([Parameter(Mandatory = $true)]$Registration)
    return [ordered]@{
        InstallLocation = [string]$Registration.InstallLocation
        NamespaceId = [string]$Registration.NamespaceId
        ItemId = [string]$Registration.ItemId
        ArtifactId = [string]$Registration.ArtifactId
        AppVersion = [string]$Registration.AppVersion
        AppName = [string]$Registration.AppName
    }
}

function New-ClientEgsLauncherInstalledPlan {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Desired
    )
    $sourceExists = Test-Path -LiteralPath $Path -PathType Leaf
    $sourceBytes = $null
    $sourceSha = ""
    if ($sourceExists) {
        $sourceBytes = [IO.File]::ReadAllBytes($Path)
        $sourceSha = Get-EgsSha256Hex $sourceBytes
        try {
            $launcher = ConvertFrom-EgsJsonBytes -Bytes $sourceBytes
        } catch {
            throw "Epic Games LauncherInstalled.dat is not valid JSON: $Path"
        }
        if ($launcher.PSObject.Properties.Name -notcontains "InstallationList") {
            throw "Epic Games LauncherInstalled.dat has no InstallationList: $Path"
        }
    } else {
        $launcher = [pscustomobject]@{ InstallationList = @() }
    }

    $desiredByApp = @{}
    foreach ($entry in $Desired) {
        $desiredByApp[[string]$entry.AppName] = $entry
    }
    $kept = @()
    $matchingApps = @{}
    $removedCount = 0
    foreach ($entry in @($launcher.InstallationList)) {
        if ($null -eq $entry) {
            $kept += $null
            continue
        }
        $appName = ""
        if ($entry.PSObject.Properties.Name -contains "AppName") {
            $appName = [string]$entry.AppName
        }
        if (-not $desiredByApp.ContainsKey($appName)) {
            $kept += $entry
            continue
        }
        $desiredEntry = $desiredByApp[$appName]
        $registration = $desiredEntry.LauncherRegistration
        $matches = if ($null -ne $registration) {
            Test-ClientEgsLauncherEntryEqualsRegistration -Entry $entry `
                -Registration $registration
        } else {
            Test-ClientEgsLauncherEntryMatches -Entry $entry -Desired $desiredEntry
        }
        if (-not $matchingApps.ContainsKey($appName) -and $matches) {
            $matchingApps[$appName] = $true
            $kept += $entry
        } else {
            $removedCount++
        }
    }

    $addedCount = 0
    foreach ($desiredEntry in @($Desired | Sort-Object AppName)) {
        if ($null -eq $desiredEntry.LauncherRegistration -or
            $matchingApps.ContainsKey([string]$desiredEntry.AppName)) {
            continue
        }
        $kept += New-ClientEgsLauncherEntry `
            -Registration $desiredEntry.LauncherRegistration
        $addedCount++
    }

    if ($removedCount -eq 0 -and $addedCount -eq 0) {
        return [pscustomobject]@{
            Path = $Path
            Desired = @($Desired)
            RequiresWrite = $false
            Bytes = $sourceBytes
            RemovedEntryCount = 0
            ImportedEntryCount = @($Desired | Where-Object {
                $null -ne $_.LauncherRegistration
            }).Count
            FallbackAppCount = @($Desired | Where-Object {
                $null -eq $_.LauncherRegistration
            }).Count
            SourceExisted = $sourceExists
            SourceSha256 = $sourceSha
        }
    }
    $launcher.InstallationList = @($kept)
    $json = $launcher | ConvertTo-Json -Depth 20
    return [pscustomobject]@{
        Path = $Path
        Desired = @($Desired)
        RequiresWrite = $true
        Bytes = [Text.Encoding]::UTF8.GetBytes($json)
        RemovedEntryCount = $removedCount
        ImportedEntryCount = @($Desired | Where-Object {
            $null -ne $_.LauncherRegistration
        }).Count
        FallbackAppCount = @($Desired | Where-Object {
            $null -eq $_.LauncherRegistration
        }).Count
        SourceExisted = $sourceExists
        SourceSha256 = $sourceSha
    }
}

function Assert-ClientEgsLauncherInstalledResult {
    param([Parameter(Mandatory = $true)]$Plan)
    $verification = New-ClientEgsLauncherInstalledPlan -Path $Plan.Path `
        -Desired $Plan.Desired
    if ($verification.RequiresWrite) {
        throw "Epic Games LauncherInstalled.dat still contains conflicting registrations"
    }
}

function Start-ClientEgsTransaction {
    param(
        [Parameter(Mandatory = $true)][string]$ManifestDirectory,
        [Parameter(Mandatory = $true)][string]$StatePath,
        [Parameter(Mandatory = $true)][string]$TransactionPath,
        [Parameter(Mandatory = $true)]$AffectedFileNames,
        [Parameter(Mandatory = $true)]$LauncherInstalledPlan
    )
    if (Test-Path -LiteralPath $TransactionPath) {
        throw "An unrecovered Epic Games manifest transaction already exists"
    }
    try {
        $backupDirectory = Join-Path $TransactionPath "backup"
        New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
        if (-not (Test-Path -LiteralPath $ManifestDirectory)) {
            New-Item -ItemType Directory -Path $ManifestDirectory -Force | Out-Null
        }

        $files = @()
        $index = 0
        foreach ($fileName in $AffectedFileNames) {
            if ([IO.Path]::GetFileName($fileName) -ne $fileName -or $fileName -notlike "*.item") {
                throw "Unsafe Epic Games manifest transaction filename: $fileName"
            }
            $target = Join-Path $ManifestDirectory $fileName
            $exists = Test-Path -LiteralPath $target -PathType Leaf
            $backupName = "$index.bak"
            $sha = ""
            if ($exists) {
                $bytes = [IO.File]::ReadAllBytes($target)
                $sha = Get-EgsSha256Hex $bytes
                [IO.File]::WriteAllBytes((Join-Path $backupDirectory $backupName), $bytes)
            }
            $files += [ordered]@{
                file_name = $fileName
                existed = $exists
                sha256 = $sha
                backup_name = $backupName
            }
            $index++
        }

        $stateExists = Test-Path -LiteralPath $StatePath -PathType Leaf
        $stateSha = ""
        if ($stateExists) {
            $stateBytes = [IO.File]::ReadAllBytes($StatePath)
            $stateSha = Get-EgsSha256Hex $stateBytes
            [IO.File]::WriteAllBytes((Join-Path $backupDirectory "state.bak"), $stateBytes)
        }

        $launcherMutated = [bool]$LauncherInstalledPlan.RequiresWrite
        $launcherPath = [string]$LauncherInstalledPlan.Path
        $launcherExists = $false
        $launcherSha = ""
        if ($launcherMutated) {
            if ([string]::IsNullOrWhiteSpace($launcherPath)) {
                throw "Epic Games LauncherInstalled.dat transaction path is empty"
            }
            $launcherExists = Test-Path -LiteralPath $launcherPath -PathType Leaf
            if ($launcherExists -ne [bool]$LauncherInstalledPlan.SourceExisted) {
                throw "Epic Games LauncherInstalled.dat changed before transaction"
            }
            if ($launcherExists) {
                $launcherBytes = [IO.File]::ReadAllBytes($launcherPath)
                $launcherSha = Get-EgsSha256Hex $launcherBytes
                if ($launcherSha -ne [string]$LauncherInstalledPlan.SourceSha256) {
                    throw "Epic Games LauncherInstalled.dat changed before transaction"
                }
                [IO.File]::WriteAllBytes(
                    (Join-Path $backupDirectory "launcher-installed.bak"),
                    $launcherBytes
                )
            }
        }
        $journal = [ordered]@{
            schema_version = 2
            manifest_directory = $ManifestDirectory
            state_path = $StatePath
            files = $files
            state_existed = $stateExists
            state_sha256 = $stateSha
            launcher_installed_mutated = $launcherMutated
            launcher_installed_path = $launcherPath
            launcher_installed_existed = $launcherExists
            launcher_installed_sha256 = $launcherSha
        }
        $journalPath = Join-Path $TransactionPath "journal.json"
        [IO.File]::WriteAllText(
            $journalPath,
            ($journal | ConvertTo-Json -Depth 6),
            (New-Object Text.UTF8Encoding($false))
        )
    } catch {
        Remove-Item -LiteralPath $TransactionPath -Recurse -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Write-ClientEgsArchiveBytes {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][string]$Sha256
    )
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        if ((Get-EgsSha256Hex ([IO.File]::ReadAllBytes($Path))) -ne $Sha256) {
            throw "Epic Games displaced registration archive hash collision"
        }
        return
    }
    Write-EgsBytesAtomic -Path $Path -Bytes $Bytes
    if ((Get-EgsSha256Hex ([IO.File]::ReadAllBytes($Path))) -ne $Sha256) {
        throw "Epic Games displaced registration archive verification failed"
    }
}

function Save-ClientEgsDisplacedRegistrations {
    param(
        [Parameter(Mandatory = $true)][string]$TransactionPath,
        [Parameter(Mandatory = $true)][string]$ArchiveDirectory,
        [Parameter(Mandatory = $true)]$DisplacedFileNames,
        [Parameter(Mandatory = $true)]$LauncherInstalledPlan
    )
    $journalPath = Join-Path $TransactionPath "journal.json"
    $journal = Get-Content -LiteralPath $journalPath -Raw | ConvertFrom-Json
    if ([int]$journal.schema_version -ne 2) {
        throw "Epic Games archive requires a version 2 transaction journal"
    }
    $backupDirectory = Join-Path $TransactionPath "backup"
    $displaced = @{}
    foreach ($fileName in $DisplacedFileNames) { $displaced[[string]$fileName] = $true }

    foreach ($entry in @($journal.files)) {
        $fileName = [string]$entry.file_name
        if (-not $displaced.ContainsKey($fileName) -or -not [bool]$entry.existed) { continue }
        $bytes = [IO.File]::ReadAllBytes(
            (Join-Path $backupDirectory ([string]$entry.backup_name))
        )
        $sha = [string]$entry.sha256
        if ((Get-EgsSha256Hex $bytes) -ne $sha) {
            throw "Epic Games displaced manifest backup hash mismatch"
        }
        $archivePath = Join-Path (Join-Path $ArchiveDirectory "items") "$sha.item"
        Write-ClientEgsArchiveBytes -Path $archivePath -Bytes $bytes -Sha256 $sha
    }

    if ($LauncherInstalledPlan.RequiresWrite -and
        [bool]$journal.launcher_installed_existed) {
        $bytes = [IO.File]::ReadAllBytes(
            (Join-Path $backupDirectory "launcher-installed.bak")
        )
        $sha = [string]$journal.launcher_installed_sha256
        if ((Get-EgsSha256Hex $bytes) -ne $sha) {
            throw "Epic Games LauncherInstalled.dat backup hash mismatch"
        }
        $archivePath = Join-Path (
            Join-Path $ArchiveDirectory "launcher-installed"
        ) "$sha.dat"
        Write-ClientEgsArchiveBytes -Path $archivePath -Bytes $bytes -Sha256 $sha
    }
}

function Get-ClientEgsAggressiveTargetPath {
    param(
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$ProgramDataPath,
        [Parameter(Mandatory = $true)][string]$LauncherInstalledPath,
        [Parameter(Mandatory = $true)][string]$SharedInstallDbPath
    )
    $safe = ConvertTo-ClientEgsArchiveRelativePath $RelativePath
    if ($safe -ceq "UnrealEngineLauncher/LauncherInstalled.dat") {
        return $LauncherInstalledPath
    }
    $prefix = "EpicGamesLauncher/Data/"
    if (-not $safe.StartsWith($prefix, [StringComparison]::Ordinal)) {
        $sharedPrefix = "EpicOnlineServicesShared/InstallHelper/InstalledItems/"
        if ($safe.StartsWith($sharedPrefix, [StringComparison]::Ordinal)) {
            return Join-ClientEgsRelativePath -Root $SharedInstallDbPath `
                -RelativePath $safe.Substring($sharedPrefix.Length)
        }
        throw "Epic Games aggressive index contains an unsupported target"
    }
    return Join-ClientEgsRelativePath -Root $ProgramDataPath `
        -RelativePath $safe.Substring($prefix.Length)
}

function Assert-ClientEgsAggressiveTree {
    param(
        [Parameter(Mandatory = $true)]$IndexData,
        [Parameter(Mandatory = $true)][string]$ProgramDataPath,
        [Parameter(Mandatory = $true)][string]$LauncherInstalledPath,
        [Parameter(Mandatory = $true)][string]$SharedInstallDbPath
    )
    if (-not (Test-Path -LiteralPath $ProgramDataPath -PathType Container) -or
        -not (Test-Path -LiteralPath $LauncherInstalledPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $SharedInstallDbPath -PathType Container)) {
        throw "Epic Games aggressive target tree is incomplete"
    }
    $expectedData = @($IndexData.Files | Where-Object {
        $_.RelativePath.StartsWith("EpicGamesLauncher/Data/", [StringComparison]::Ordinal)
    })
    $actualData = @(Get-ChildItem -LiteralPath $ProgramDataPath -Recurse -Force -File)
    if ($actualData.Count -ne $expectedData.Count) {
        throw "Epic Games aggressive target has an unexpected file set"
    }
    $seen = @{}
    foreach ($file in $actualData) {
        if (([int]$file.Attributes -band [int][IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Epic Games aggressive target contains a reparse point"
        }
        $root = (Get-Item -LiteralPath $ProgramDataPath -Force).FullName.TrimEnd(
            [char[]]@(92, 47)
        )
        $relative = $file.FullName.Substring($root.Length).TrimStart(
            [char[]]@(92, 47)
        ).Replace("\", "/")
        $key = "EpicGamesLauncher/Data/$relative"
        if ($seen.ContainsKey($key)) {
            throw "Epic Games aggressive target contains a path collision"
        }
        $seen[$key] = $file
    }
    $expectedShared = @($IndexData.Files | Where-Object {
        $_.RelativePath.StartsWith(
            "EpicOnlineServicesShared/InstallHelper/InstalledItems/",
            [StringComparison]::Ordinal
        )
    })
    $actualShared = @(Get-ChildItem -LiteralPath $SharedInstallDbPath -Recurse -Force -File)
    if ($actualShared.Count -ne $expectedShared.Count) {
        throw "Epic Games aggressive shared installation database has an unexpected file set"
    }
    $sharedRoot = (Get-Item -LiteralPath $SharedInstallDbPath -Force).FullName.TrimEnd(
        [char[]]@(92, 47)
    )
    foreach ($file in $actualShared) {
        if (([int]$file.Attributes -band [int][IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Epic Games aggressive shared installation database contains a reparse point"
        }
        $relative = $file.FullName.Substring($sharedRoot.Length).TrimStart(
            [char[]]@(92, 47)
        ).Replace("\", "/")
        $key = "EpicOnlineServicesShared/InstallHelper/InstalledItems/$relative"
        if ($seen.ContainsKey($key)) {
            throw "Epic Games aggressive target contains a path collision"
        }
        $seen[$key] = $file
    }
    foreach ($expected in $IndexData.Files) {
        $target = Get-ClientEgsAggressiveTargetPath `
            -RelativePath $expected.RelativePath -ProgramDataPath $ProgramDataPath `
            -LauncherInstalledPath $LauncherInstalledPath `
            -SharedInstallDbPath $SharedInstallDbPath
        if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
            throw "Epic Games aggressive target file verification failed"
        }
        $targetItem = Get-Item -LiteralPath $target -Force
        if ([Int64]$targetItem.Length -ne [Int64]$expected.Length -or
            (Get-EgsFileSha256Hex -Path $target) -ne [string]$expected.Sha256) {
            throw "Epic Games aggressive target file verification failed"
        }
    }
    $expectedDirectories = @($IndexData.Directories | Where-Object {
        $_.RelativePath -ceq "EpicGamesLauncher/Data" -or
        $_.RelativePath.StartsWith(
            "EpicGamesLauncher/Data/", [StringComparison]::Ordinal
        )
    })
    $actualDirectoryCount = 1 + @(
        Get-ChildItem -LiteralPath $ProgramDataPath -Recurse -Force -Directory
    ).Count
    if ($actualDirectoryCount -ne $expectedDirectories.Count) {
        throw "Epic Games aggressive target has an unexpected directory set"
    }
    foreach ($expected in $expectedDirectories) {
        if ($expected.RelativePath -ceq "EpicGamesLauncher/Data") {
            $target = $ProgramDataPath
        } else {
            $target = Join-ClientEgsRelativePath -Root $ProgramDataPath `
                -RelativePath $expected.RelativePath.Substring(
                    "EpicGamesLauncher/Data/".Length
                )
        }
        if (-not (Test-Path -LiteralPath $target -PathType Container)) {
            throw "Epic Games aggressive target directory verification failed"
        }
        $targetItem = Get-Item -LiteralPath $target -Force
        if (([int]$targetItem.Attributes -band
            [int][IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Epic Games aggressive target contains a reparse directory"
        }
    }
    $expectedSharedDirectories = @($IndexData.Directories | Where-Object {
        $_.RelativePath -ceq "EpicOnlineServicesShared/InstallHelper/InstalledItems" -or
        $_.RelativePath.StartsWith(
            "EpicOnlineServicesShared/InstallHelper/InstalledItems/",
            [StringComparison]::Ordinal
        )
    })
    $actualSharedDirectoryCount = 1 + @(
        Get-ChildItem -LiteralPath $SharedInstallDbPath -Recurse -Force -Directory
    ).Count
    if ($actualSharedDirectoryCount -ne $expectedSharedDirectories.Count) {
        throw "Epic Games aggressive shared installation database has an unexpected directory set"
    }
    foreach ($expected in $expectedSharedDirectories) {
        if ($expected.RelativePath -ceq
            "EpicOnlineServicesShared/InstallHelper/InstalledItems") {
            $target = $SharedInstallDbPath
        } else {
            $target = Join-ClientEgsRelativePath -Root $SharedInstallDbPath `
                -RelativePath $expected.RelativePath.Substring(
                    "EpicOnlineServicesShared/InstallHelper/InstalledItems/".Length
                )
        }
        if (-not (Test-Path -LiteralPath $target -PathType Container)) {
            throw "Epic Games aggressive shared installation database directory verification failed"
        }
        $targetItem = Get-Item -LiteralPath $target -Force
        if (([int]$targetItem.Attributes -band
            [int][IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Epic Games aggressive shared installation database contains a reparse directory"
        }
    }
}

function Assert-ClientEgsAggressiveInventory {
    param(
        [Parameter(Mandatory = $true)][string]$ManifestDirectory,
        [Parameter(Mandatory = $true)]$Desired
    )
    $actual = @(Read-ExistingEgsManifests -ManifestDirectory $ManifestDirectory)
    if ($actual.Count -ne @($Desired).Count) {
        throw "Epic Games aggressive manifest inventory count does not match the release"
    }
    foreach ($desiredEntry in $Desired) {
        $matches = @($actual | Where-Object { $_.AppName -eq $desiredEntry.AppName })
        if ($matches.Count -ne 1 -or
            $matches[0].FileName -ne $desiredEntry.TargetFileName -or
            $matches[0].Sha256 -ne $desiredEntry.Sha256) {
            throw "Epic Games aggressive manifest inventory verification failed"
        }
    }
}

function Assert-ClientEgsAggressiveLocalTargetsSafe {
    param(
        [Parameter(Mandatory = $true)][string]$ProgramDataPath,
        [Parameter(Mandatory = $true)][string]$LauncherInstalledPath,
        [Parameter(Mandatory = $true)][string]$SharedInstallDbPath
    )
    if (Test-Path -LiteralPath $ProgramDataPath) {
        $root = Get-Item -LiteralPath $ProgramDataPath -Force
        if (-not $root.PSIsContainer -or
            (([int]$root.Attributes -band [int][IO.FileAttributes]::ReparsePoint) -ne 0)) {
            throw "Existing Epic Games ProgramData target is unsafe"
        }
        foreach ($item in @(Get-ChildItem -LiteralPath $ProgramDataPath -Recurse -Force)) {
            if (([int]$item.Attributes -band [int][IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Existing Epic Games ProgramData contains a reparse point"
            }
        }
    }
    if (Test-Path -LiteralPath $LauncherInstalledPath) {
        $launcher = Get-Item -LiteralPath $LauncherInstalledPath -Force
        if ($launcher.PSIsContainer -or
            (([int]$launcher.Attributes -band [int][IO.FileAttributes]::ReparsePoint) -ne 0)) {
            throw "Existing LauncherInstalled.dat target is unsafe"
        }
    }
    if (Test-Path -LiteralPath $SharedInstallDbPath) {
        $root = Get-Item -LiteralPath $SharedInstallDbPath -Force
        if (-not $root.PSIsContainer -or
            (([int]$root.Attributes -band [int][IO.FileAttributes]::ReparsePoint) -ne 0)) {
            throw "Existing Epic Games shared installation database target is unsafe"
        }
        foreach ($item in @(Get-ChildItem -LiteralPath $SharedInstallDbPath -Recurse -Force)) {
            if (([int]$item.Attributes -band [int][IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Existing Epic Games shared installation database contains a reparse point"
            }
        }
    }
}

function Get-ClientEgsAggressiveStateSha256 {
    param(
        [Parameter(Mandatory = $true)][string]$ProgramDataPath,
        [Parameter(Mandatory = $true)][string]$LauncherInstalledPath,
        [string]$SharedInstallDbPath = ""
    )
    $records = @()
    if (Test-Path -LiteralPath $ProgramDataPath -PathType Container) {
        $root = (Get-Item -LiteralPath $ProgramDataPath -Force).FullName.TrimEnd(
            [char[]]@(92, 47)
        )
        $records += "R/Data"
        foreach ($directory in @(
            Get-ChildItem -LiteralPath $ProgramDataPath -Recurse -Force -Directory
        )) {
            if (([int]$directory.Attributes -band
                [int][IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Epic Games displaced ProgramData contains a reparse point"
            }
            $relative = $directory.FullName.Substring($root.Length).TrimStart(
                [char[]]@(92, 47)
            ).Replace("\", "/")
            $records += "R/Data/$relative"
        }
        foreach ($file in @(Get-ChildItem -LiteralPath $ProgramDataPath -Recurse -Force -File)) {
            if (([int]$file.Attributes -band [int][IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Epic Games displaced ProgramData contains a reparse point"
            }
            $relative = $file.FullName.Substring($root.Length).TrimStart(
                [char[]]@(92, 47)
            ).Replace("\", "/")
            $records += "D/$relative`n$([Int64]$file.Length)`n$(Get-EgsFileSha256Hex $file.FullName)"
        }
    }
    if (Test-Path -LiteralPath $LauncherInstalledPath -PathType Leaf) {
        $file = Get-Item -LiteralPath $LauncherInstalledPath -Force
        if (([int]$file.Attributes -band [int][IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Epic Games displaced LauncherInstalled.dat is a reparse point"
        }
        $records += "L/LauncherInstalled.dat`n$([Int64]$file.Length)`n$(Get-EgsFileSha256Hex $file.FullName)"
    }
    if (-not [string]::IsNullOrWhiteSpace($SharedInstallDbPath) -and
        (Test-Path -LiteralPath $SharedInstallDbPath -PathType Container)) {
        $root = (Get-Item -LiteralPath $SharedInstallDbPath -Force).FullName.TrimEnd(
            [char[]]@(92, 47)
        )
        $records += "R/SharedInstallDb"
        foreach ($directory in @(
            Get-ChildItem -LiteralPath $SharedInstallDbPath -Recurse -Force -Directory
        )) {
            if (([int]$directory.Attributes -band
                [int][IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Epic Games displaced shared installation database contains a reparse point"
            }
            $relative = $directory.FullName.Substring($root.Length).TrimStart(
                [char[]]@(92, 47)
            ).Replace("\", "/")
            $records += "R/SharedInstallDb/$relative"
        }
        foreach ($file in @(
            Get-ChildItem -LiteralPath $SharedInstallDbPath -Recurse -Force -File
        )) {
            if (([int]$file.Attributes -band [int][IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Epic Games displaced shared installation database contains a reparse point"
            }
            $relative = $file.FullName.Substring($root.Length).TrimStart(
                [char[]]@(92, 47)
            ).Replace("\", "/")
            $records += "S/$relative`n$([Int64]$file.Length)`n$(Get-EgsFileSha256Hex $file.FullName)"
        }
    }
    $text = (@($records | Sort-Object) -join "`n")
    return Get-EgsSha256Hex ([Text.Encoding]::UTF8.GetBytes($text))
}

function Reset-ClientEgsInheritedAcl {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { return }
    $icacls = Join-Path $env:SystemRoot "System32\icacls.exe"
    & $icacls $Path "/reset" "/T" "/C" "/Q" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Epic Games local state ACL inheritance reset failed"
    }
}

function Set-ClientEgsIndexedFileMetadata {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Entry
    )
    [IO.File]::SetCreationTimeUtc(
        $Path,
        [DateTime]::Parse(
            $Entry.CreationTimeUtc,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind
        ).ToUniversalTime()
    )
    [IO.File]::SetLastWriteTimeUtc(
        $Path,
        [DateTime]::Parse(
            $Entry.LastWriteTimeUtc,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind
        ).ToUniversalTime()
    )
    [IO.File]::SetAttributes($Path, [IO.FileAttributes]$Entry.Attributes)
}

function Save-ClientEgsAggressiveBackup {
    param(
        [Parameter(Mandatory = $true)][string]$TransactionPath,
        [Parameter(Mandatory = $true)][string]$BackupRoot,
        [Parameter(Mandatory = $true)]$Journal
    )
    $transactionBackup = Join-Path $TransactionPath "backup"
    $oldData = Join-Path $transactionBackup "Data"
    $oldLauncher = Join-Path $transactionBackup "launcher-installed.bak"
    $oldSharedInstallDb = Join-Path $transactionBackup "SharedInstallDb"
    $fingerprint = Get-ClientEgsAggressiveStateSha256 -ProgramDataPath $oldData `
        -LauncherInstalledPath $oldLauncher -SharedInstallDbPath $oldSharedInstallDb
    $destination = Join-Path $BackupRoot $fingerprint
    if (Test-Path -LiteralPath (Join-Path $destination "backup.json") -PathType Leaf) {
        $existingMetadata = Get-Content -LiteralPath (Join-Path $destination "backup.json") `
            -Raw | ConvertFrom-Json
        if ([int]$existingMetadata.schema_version -notin @(1, 2) -or
            [string]$existingMetadata.state_sha256 -ne $fingerprint -or
            (Get-ClientEgsAggressiveStateSha256 `
                -ProgramDataPath (Join-Path $destination "Data") `
                -LauncherInstalledPath (Join-Path $destination "LauncherInstalled.dat") `
                -SharedInstallDbPath (Join-Path $destination "SharedInstallDb")) -ne
                $fingerprint) {
            throw "Existing Epic Games displaced ProgramData backup is invalid"
        }
        return $fingerprint
    }
    if (Test-Path -LiteralPath $destination) {
        throw "Existing Epic Games displaced ProgramData backup is incomplete"
    }
    if (-not (Test-Path -LiteralPath $BackupRoot)) {
        New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null
    }
    $temporary = Join-Path $BackupRoot (".egs-backup-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $temporary -Force | Out-Null
    try {
        if ([bool]$Journal.data_existed) {
            Copy-Item -LiteralPath $oldData -Destination (Join-Path $temporary "Data") `
                -Recurse -Force
        }
        if ([bool]$Journal.launcher_installed_existed) {
            Copy-Item -LiteralPath $oldLauncher `
                -Destination (Join-Path $temporary "LauncherInstalled.dat") -Force
        }
        if ([bool]$Journal.shared_install_db_existed) {
            Copy-Item -LiteralPath $oldSharedInstallDb `
                -Destination (Join-Path $temporary "SharedInstallDb") -Recurse -Force
        }
        $metadata = [ordered]@{
            schema_version = 2
            state_sha256 = $fingerprint
            data_existed = [bool]$Journal.data_existed
            launcher_installed_existed = [bool]$Journal.launcher_installed_existed
            shared_install_db_existed = [bool]$Journal.shared_install_db_existed
            created_at = [DateTime]::UtcNow.ToString("o")
        } | ConvertTo-Json -Depth 3
        Write-EgsBytesAtomic -Path (Join-Path $temporary "backup.json") `
            -Bytes ([Text.Encoding]::UTF8.GetBytes($metadata))
        $copiedData = Join-Path $temporary "Data"
        $copiedLauncher = Join-Path $temporary "LauncherInstalled.dat"
        $copiedSharedInstallDb = Join-Path $temporary "SharedInstallDb"
        if ((Get-ClientEgsAggressiveStateSha256 -ProgramDataPath $copiedData `
            -LauncherInstalledPath $copiedLauncher `
            -SharedInstallDbPath $copiedSharedInstallDb) -ne $fingerprint) {
            throw "Epic Games displaced ProgramData backup verification failed"
        }
        if (-not (Test-Path -LiteralPath $destination)) {
            Move-Item -LiteralPath $temporary -Destination $destination
        }
    } finally {
        Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
    }
    return $fingerprint
}

function Start-ClientEgsAggressiveTransaction {
    param(
        [Parameter(Mandatory = $true)][string]$TransactionPath,
        [Parameter(Mandatory = $true)][string]$ProgramDataPath,
        [Parameter(Mandatory = $true)][string]$LauncherInstalledPath,
        [Parameter(Mandatory = $true)][string]$SharedInstallDbPath,
        [Parameter(Mandatory = $true)][string]$StatePath,
        [Parameter(Mandatory = $true)][string]$AggressiveStatePath,
        [Parameter(Mandatory = $true)][string]$StagePath
    )
    if (Test-Path -LiteralPath $TransactionPath) {
        throw "Epic Games manifest transaction already exists"
    }
    $backupDirectory = Join-Path $TransactionPath "backup"
    New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
    $journal = [ordered]@{
        schema_version = 4
        program_data_path = $ProgramDataPath
        launcher_installed_path = $LauncherInstalledPath
        shared_install_db_path = $SharedInstallDbPath
        state_path = $StatePath
        aggressive_state_path = $AggressiveStatePath
        stage_path = $StagePath
        data_existed = Test-Path -LiteralPath $ProgramDataPath -PathType Container
        launcher_installed_existed = Test-Path -LiteralPath $LauncherInstalledPath -PathType Leaf
        shared_install_db_existed = Test-Path -LiteralPath $SharedInstallDbPath -PathType Container
        state_existed = Test-Path -LiteralPath $StatePath -PathType Leaf
        aggressive_state_existed = Test-Path -LiteralPath $AggressiveStatePath -PathType Leaf
        launcher_installed_sha256 = ""
        launcher_installed_attributes = 0
        launcher_installed_creation_time_utc = ""
        launcher_installed_last_write_time_utc = ""
        state_sha256 = ""
        aggressive_state_sha256 = ""
    }
    if ([bool]$journal.launcher_installed_existed) {
        $launcherItem = Get-Item -LiteralPath $LauncherInstalledPath -Force
        $journal.launcher_installed_attributes = [int]$launcherItem.Attributes
        $journal.launcher_installed_creation_time_utc =
            $launcherItem.CreationTimeUtc.ToString("o")
        $journal.launcher_installed_last_write_time_utc =
            $launcherItem.LastWriteTimeUtc.ToString("o")
    }
    foreach ($copy in @(
        [pscustomobject]@{ Exists = $journal.launcher_installed_existed; Source = $LauncherInstalledPath; Name = "launcher-installed.bak"; Sha = "launcher_installed_sha256" },
        [pscustomobject]@{ Exists = $journal.state_existed; Source = $StatePath; Name = "state.bak"; Sha = "state_sha256" },
        [pscustomobject]@{ Exists = $journal.aggressive_state_existed; Source = $AggressiveStatePath; Name = "aggressive-state.bak"; Sha = "aggressive_state_sha256" }
    )) {
        if ([bool]$copy.Exists) {
            $bytes = [IO.File]::ReadAllBytes([string]$copy.Source)
            [IO.File]::WriteAllBytes((Join-Path $backupDirectory $copy.Name), $bytes)
            $journal[$copy.Sha] = Get-EgsSha256Hex $bytes
        }
    }
    Write-EgsBytesAtomic -Path (Join-Path $TransactionPath "journal.json") `
        -Bytes ([Text.Encoding]::UTF8.GetBytes(($journal | ConvertTo-Json -Depth 5)))
    return [pscustomobject]$journal
}

function Restore-ClientEgsAggressiveTransaction {
    param(
        [Parameter(Mandatory = $true)][string]$TransactionPath,
        [Parameter(Mandatory = $true)]$Journal
    )
    $backupDirectory = Join-Path $TransactionPath "backup"
    $errors = @()
    $programDataPath = [string]$Journal.program_data_path
    try {
        $oldData = Join-Path $backupDirectory "Data"
        if ([bool]$Journal.data_existed) {
            if (Test-Path -LiteralPath $oldData -PathType Container) {
                if (Test-Path -LiteralPath $programDataPath) {
                    Remove-Item -LiteralPath $programDataPath -Recurse -Force
                }
                $parent = Split-Path $programDataPath -Parent
                if (-not (Test-Path -LiteralPath $parent)) {
                    New-Item -ItemType Directory -Path $parent -Force | Out-Null
                }
                Move-Item -LiteralPath $oldData -Destination $programDataPath
            } elseif (-not (Test-Path -LiteralPath $programDataPath -PathType Container)) {
                throw "Original ProgramData tree is unavailable"
            }
        } elseif (Test-Path -LiteralPath $programDataPath) {
            Remove-Item -LiteralPath $programDataPath -Recurse -Force
        }
    } catch { $errors += "ProgramData: $($_.Exception.Message)" }

    if ($Journal.PSObject.Properties.Name -contains "shared_install_db_path") {
        $sharedInstallDbPath = [string]$Journal.shared_install_db_path
        try {
            $oldSharedInstallDb = Join-Path $backupDirectory "SharedInstallDb"
            if ([bool]$Journal.shared_install_db_existed) {
                if (Test-Path -LiteralPath $oldSharedInstallDb -PathType Container) {
                    if (Test-Path -LiteralPath $sharedInstallDbPath) {
                        Remove-Item -LiteralPath $sharedInstallDbPath -Recurse -Force
                    }
                    $parent = Split-Path $sharedInstallDbPath -Parent
                    if (-not (Test-Path -LiteralPath $parent)) {
                        New-Item -ItemType Directory -Path $parent -Force | Out-Null
                    }
                    Move-Item -LiteralPath $oldSharedInstallDb `
                        -Destination $sharedInstallDbPath
                } elseif (-not (Test-Path -LiteralPath $sharedInstallDbPath -PathType Container)) {
                    throw "Original shared installation database is unavailable"
                }
            } elseif (Test-Path -LiteralPath $sharedInstallDbPath) {
                Remove-Item -LiteralPath $sharedInstallDbPath -Recurse -Force
            }
        } catch { $errors += "SharedInstallDb: $($_.Exception.Message)" }
    }

    foreach ($restore in @(
        [pscustomobject]@{ Exists = $Journal.launcher_installed_existed; Target = [string]$Journal.launcher_installed_path; Name = "launcher-installed.bak"; Sha = [string]$Journal.launcher_installed_sha256 },
        [pscustomobject]@{ Exists = $Journal.state_existed; Target = [string]$Journal.state_path; Name = "state.bak"; Sha = [string]$Journal.state_sha256 },
        [pscustomobject]@{ Exists = $Journal.aggressive_state_existed; Target = [string]$Journal.aggressive_state_path; Name = "aggressive-state.bak"; Sha = [string]$Journal.aggressive_state_sha256 }
    )) {
        try {
            if ([bool]$restore.Exists) {
                $bytes = [IO.File]::ReadAllBytes((Join-Path $backupDirectory $restore.Name))
                if ((Get-EgsSha256Hex $bytes) -ne $restore.Sha) { throw "Backup hash mismatch" }
                Write-EgsBytesAtomic -Path $restore.Target -Bytes $bytes
                if ($restore.Name -eq "launcher-installed.bak") {
                    Set-ClientEgsIndexedFileMetadata -Path $restore.Target `
                        -Entry ([pscustomobject]@{
                            Attributes = [int]$Journal.launcher_installed_attributes
                            CreationTimeUtc =
                                [string]$Journal.launcher_installed_creation_time_utc
                            LastWriteTimeUtc =
                                [string]$Journal.launcher_installed_last_write_time_utc
                        })
                }
            } elseif (Test-Path -LiteralPath $restore.Target) {
                Remove-Item -LiteralPath $restore.Target -Force
            }
        } catch { $errors += "$($restore.Name): $($_.Exception.Message)" }
    }
    if ($errors.Count -gt 0) {
        throw ("Epic Games aggressive rollback is incomplete: " + ($errors -join "; "))
    }
    Remove-Item -LiteralPath ([string]$Journal.stage_path) -Recurse -Force `
        -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $TransactionPath -Recurse -Force
}

function Restore-ClientEgsTransaction {
    param([Parameter(Mandatory = $true)][string]$TransactionPath)
    Assert-EgsLauncherStopped
    $journalPath = Join-Path $TransactionPath "journal.json"
    if (-not (Test-Path -LiteralPath $journalPath -PathType Leaf)) {
        throw "Epic Games manifest transaction journal is missing"
    }
    $journal = Get-Content -LiteralPath $journalPath -Raw | ConvertFrom-Json
    $journalVersion = [int]$journal.schema_version
    if ($journalVersion -in @(3, 4)) {
        if ($journalVersion -eq 4) {
            Wait-EgsSharedInstallDbIdle -InstallDbPath ([string]$journal.shared_install_db_path)
        }
        Restore-ClientEgsAggressiveTransaction -TransactionPath $TransactionPath `
            -Journal $journal
        return
    }
    if ($journalVersion -notin @(1, 2)) {
        throw "Epic Games manifest transaction journal version is unsupported"
    }
    $manifestDirectory = [string]$journal.manifest_directory
    $statePath = [string]$journal.state_path
    $backupDirectory = Join-Path $TransactionPath "backup"
    $errors = @()

    foreach ($entry in @($journal.files)) {
        try {
            $fileName = [string]$entry.file_name
            if ([IO.Path]::GetFileName($fileName) -ne $fileName -or $fileName -notlike "*.item") {
                throw "Unsafe transaction filename"
            }
            $target = Join-Path $manifestDirectory $fileName
            if ([bool]$entry.existed) {
                $backup = Join-Path $backupDirectory ([string]$entry.backup_name)
                $bytes = [IO.File]::ReadAllBytes($backup)
                if ((Get-EgsSha256Hex $bytes) -ne [string]$entry.sha256) {
                    throw "Backup hash mismatch"
                }
                Write-EgsBytesAtomic -Path $target -Bytes $bytes
                if ((Get-EgsSha256Hex ([IO.File]::ReadAllBytes($target))) -ne
                    [string]$entry.sha256) {
                    throw "Restored manifest hash mismatch"
                }
            } elseif (Test-Path -LiteralPath $target) {
                Remove-Item -LiteralPath $target -Force
            }
        } catch {
            $errors += "$($entry.file_name): $($_.Exception.Message)"
        }
    }

    try {
        if ([bool]$journal.state_existed) {
            $bytes = [IO.File]::ReadAllBytes((Join-Path $backupDirectory "state.bak"))
            if ((Get-EgsSha256Hex $bytes) -ne [string]$journal.state_sha256) {
                throw "Managed state backup hash mismatch"
            }
            Write-EgsBytesAtomic -Path $statePath -Bytes $bytes
        } elseif (Test-Path -LiteralPath $statePath) {
            Remove-Item -LiteralPath $statePath -Force
        }
    } catch {
        $errors += "managed state: $($_.Exception.Message)"
    }
    if ($journalVersion -eq 2 -and [bool]$journal.launcher_installed_mutated) {
        try {
            $launcherPath = [string]$journal.launcher_installed_path
            if ([string]::IsNullOrWhiteSpace($launcherPath)) {
                throw "LauncherInstalled.dat rollback path is empty"
            }
            if ([bool]$journal.launcher_installed_existed) {
                $bytes = [IO.File]::ReadAllBytes(
                    (Join-Path $backupDirectory "launcher-installed.bak")
                )
                if ((Get-EgsSha256Hex $bytes) -ne
                    [string]$journal.launcher_installed_sha256) {
                    throw "LauncherInstalled.dat backup hash mismatch"
                }
                Write-EgsBytesAtomic -Path $launcherPath -Bytes $bytes
                if ((Get-EgsSha256Hex ([IO.File]::ReadAllBytes($launcherPath))) -ne
                    [string]$journal.launcher_installed_sha256) {
                    throw "Restored LauncherInstalled.dat hash mismatch"
                }
            } elseif (Test-Path -LiteralPath $launcherPath) {
                Remove-Item -LiteralPath $launcherPath -Force
            }
        } catch {
            $errors += "LauncherInstalled.dat: $($_.Exception.Message)"
        }
    }
    if ($errors.Count -gt 0) {
        throw ("Epic Games manifest rollback is incomplete: " + ($errors -join "; "))
    }
    Assert-EgsLauncherStopped
    Remove-Item -LiteralPath $TransactionPath -Recurse -Force
}

function Write-ClientEgsManagedState {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Desired
    )
    $state = [ordered]@{
        schema_version = 1
        manifests = @($Desired | Sort-Object AppName | ForEach-Object {
            [ordered]@{
                app_name = $_.AppName
                installation_guid = $_.InstallationGuid
                install_location = $_.InstallLocation
                sha256 = $_.Sha256
            }
        })
    }
    $json = $state | ConvertTo-Json -Depth 5
    Write-EgsBytesAtomic -Path $Path -Bytes ([Text.Encoding]::UTF8.GetBytes($json))
}

function Assert-ClientEgsSyncResult {
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [Parameter(Mandatory = $true)][string]$ManifestDirectory,
        [Parameter(Mandatory = $true)][string]$StatePath,
        [Parameter(Mandatory = $true)]$LauncherInstalledPlan
    )
    $current = @(Read-ExistingEgsManifests -ManifestDirectory $ManifestDirectory)
    foreach ($desired in $Plan.Desired) {
        $matches = @($current | Where-Object { $_.AppName -eq $desired.AppName })
        if ($matches.Count -ne 1 -or
            $matches[0].FileName -ne $desired.TargetFileName -or
            $matches[0].Sha256 -ne $desired.Sha256) {
            throw "Epic Games manifest commit verification failed for $($desired.AppName)"
        }
    }
    $desiredNames = @{}
    foreach ($desired in $Plan.Desired) { $desiredNames[$desired.AppName] = $true }
    foreach ($appName in $Plan.PreviouslyManagedAppNames) {
        if (-not $desiredNames.ContainsKey($appName) -and
            @($current | Where-Object { $_.AppName -eq $appName }).Count -ne 0) {
            throw "Stale managed Epic Games manifest still exists: $appName"
        }
    }
    $state = Read-ClientEgsManagedState -Path $StatePath
    if (@($state.manifests).Count -ne @($Plan.Desired).Count) {
        throw "Epic Games managed state count does not match committed manifests"
    }
    foreach ($desired in $Plan.Desired) {
        $stateMatches = @($state.manifests | Where-Object {
            [string]$_.app_name -eq $desired.AppName
        })
        if ($stateMatches.Count -ne 1 -or
            [string]$stateMatches[0].installation_guid -ne $desired.InstallationGuid -or
            [string]$stateMatches[0].sha256 -ne $desired.Sha256 -or
            -not (ConvertTo-EgsCanonicalPath (
                [string]$stateMatches[0].install_location
            )).Equals($desired.InstallLocation, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Epic Games managed state verification failed for $($desired.AppName)"
        }
    }
    Assert-ClientEgsLauncherInstalledResult -Plan $LauncherInstalledPlan
}

function Invoke-ClientEgsTransaction {
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [Parameter(Mandatory = $true)][string]$ManifestDirectory,
        [Parameter(Mandatory = $true)][string]$StatePath,
        [Parameter(Mandatory = $true)][string]$TransactionPath,
        [Parameter(Mandatory = $true)][string]$ArchiveDirectory,
        [Parameter(Mandatory = $true)]$LauncherInstalledPlan
    )
    Start-ClientEgsTransaction -ManifestDirectory $ManifestDirectory -StatePath $StatePath `
        -TransactionPath $TransactionPath -AffectedFileNames $Plan.AffectedFileNames `
        -LauncherInstalledPlan $LauncherInstalledPlan
    try {
        Assert-EgsLauncherStopped
        Save-ClientEgsDisplacedRegistrations -TransactionPath $TransactionPath `
            -ArchiveDirectory $ArchiveDirectory `
            -DisplacedFileNames $Plan.DisplacedFileNames `
            -LauncherInstalledPlan $LauncherInstalledPlan
        foreach ($desired in $Plan.Desired) {
            Write-EgsBytesAtomic -Path (Join-Path $ManifestDirectory $desired.TargetFileName) `
                -Bytes $desired.Bytes
        }
        foreach ($fileName in $Plan.RemoveFileNames) {
            $path = Join-Path $ManifestDirectory $fileName
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
        }
        if ($LauncherInstalledPlan.RequiresWrite) {
            Write-EgsBytesAtomic -Path $LauncherInstalledPlan.Path `
                -Bytes $LauncherInstalledPlan.Bytes
        }
        Write-ClientEgsManagedState -Path $StatePath -Desired $Plan.Desired
        Assert-EgsLauncherStopped
        Assert-ClientEgsSyncResult -Plan $Plan -ManifestDirectory $ManifestDirectory `
            -StatePath $StatePath -LauncherInstalledPlan $LauncherInstalledPlan
        Assert-EgsLauncherStopped
        Remove-Item -LiteralPath $TransactionPath -Recurse -Force
    } catch {
        $failure = $_
        try { Stop-EgsLauncherProcesses } catch { }
        try {
            Restore-ClientEgsTransaction -TransactionPath $TransactionPath
        } catch {
            throw "Epic Games manifest sync failed and rollback did not complete: $($_.Exception.Message)"
        }
        throw $failure
    }
}

function Invoke-ClientEgsManifestSync {
    param(
        [Parameter(Mandatory = $true)]$ExpectedVolumes,
        [Parameter(Mandatory = $true)][string]$ConfigRevision,
        [Parameter(Mandatory = $true)][string]$SyncConfigPath,
        [string]$ManifestDirectory = "C:\ProgramData\Epic\EpicGamesLauncher\Data\Manifests",
        [string]$LauncherInstalledPath =
            "C:\ProgramData\Epic\UnrealEngineLauncher\LauncherInstalled.dat"
    )
    Stop-EgsLauncherProcesses
    $installRoot = Split-Path $SyncConfigPath -Parent
    $statePath = Join-Path $installRoot "egs-managed-apps.v1.json"
    $transactionPath = Join-Path $installRoot "egs-sync-transaction"
    $archiveDirectory = Join-Path $installRoot "egs-displaced-registrations"
    if (Test-Path -LiteralPath $transactionPath) {
        Restore-ClientEgsTransaction -TransactionPath $transactionPath
    }

    $desired = @()
    foreach ($volume in $ExpectedVolumes) {
        $letter = ([string]$volume.drive_letter).Trim().ToUpperInvariant()
        if ($letter -notmatch "^[A-Z]$") {
            throw "Invalid drive letter for Epic Games volume $($volume.name)"
        }
        $root = "$letter`:\"
        $bundlePath = Join-Path $root ".iscsi-reset\egs-manifests.v2.json"
        $legacyBundlePath = Join-Path $root ".iscsi-reset\egs-manifests.v1.json"
        if (-not (Test-Path -LiteralPath $bundlePath -PathType Leaf) -and
            (Test-Path -LiteralPath $legacyBundlePath -PathType Leaf)) {
            throw "Epic Games bundle v1 is unsupported; create a new v2 release"
        }
        $desired += @(Read-ClientEgsBundle -Path $bundlePath `
            -ConfigRevision $ConfigRevision -VolumeName ([string]$volume.name) -VolumeRoot $root)
    }
    $existing = @(Read-ExistingEgsManifests -ManifestDirectory $ManifestDirectory)
    $managed = Read-ClientEgsManagedState -Path $statePath
    $plan = New-ClientEgsSyncPlan -Desired $desired -Existing $existing -ManagedState $managed
    $launcherPlan = New-ClientEgsLauncherInstalledPlan -Path $LauncherInstalledPath `
        -Desired $desired
    Invoke-ClientEgsTransaction -Plan $plan -ManifestDirectory $ManifestDirectory `
        -StatePath $statePath -TransactionPath $transactionPath `
        -ArchiveDirectory $archiveDirectory -LauncherInstalledPlan $launcherPlan
    $warningCount = 0
    foreach ($entry in $desired) { $warningCount += @($entry.StateWarnings).Count }
    return [pscustomobject]@{
        ManifestCount = @($desired).Count
        AdoptedAppCount = @($plan.AdoptedAppNames).Count
        DisplacedManifestCount = @($plan.DisplacedFileNames).Count
        LauncherEntryRemovalCount = [int]$launcherPlan.RemovedEntryCount
        LauncherEntryImportCount = [int]$launcherPlan.ImportedEntryCount
        LauncherFallbackAppCount = [int]$launcherPlan.FallbackAppCount
        IncompleteWarningCount = $warningCount
    }
}

function Assert-ClientEgsAggressiveManagedState {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Desired
    )
    $state = Read-ClientEgsManagedState -Path $Path
    if (@($state.manifests).Count -ne @($Desired).Count) {
        throw "Epic Games aggressive managed state count is invalid"
    }
    foreach ($entry in $Desired) {
        $matches = @($state.manifests | Where-Object {
            [string]$_.app_name -eq [string]$entry.AppName
        })
        if ($matches.Count -ne 1 -or
            [string]$matches[0].installation_guid -ne [string]$entry.InstallationGuid -or
            [string]$matches[0].sha256 -ne [string]$entry.Sha256) {
            throw "Epic Games aggressive managed state verification failed"
        }
    }
}

function Invoke-ClientEgsAggressiveSync {
    param(
        [Parameter(Mandatory = $true)]$ExpectedVolumes,
        [Parameter(Mandatory = $true)][string]$ConfigRevision,
        [Parameter(Mandatory = $true)][string]$SyncConfigPath,
        [string]$ProgramDataPath = "C:\ProgramData\Epic\EpicGamesLauncher\Data",
        [string]$LauncherInstalledPath =
            "C:\ProgramData\Epic\UnrealEngineLauncher\LauncherInstalled.dat",
        [string]$SharedInstallDbPath =
            "C:\ProgramData\Epic\EpicOnlineServicesShared\InstallHelper\InstalledItems"
    )
    Stop-EgsLauncherProcesses
    Wait-EgsSharedInstallDbIdle -InstallDbPath $SharedInstallDbPath
    $installRoot = Split-Path $SyncConfigPath -Parent
    $statePath = Join-Path $installRoot "egs-managed-apps.v1.json"
    $aggressiveStatePath = Join-Path $installRoot "egs-aggressive-state.v1.json"
    $transactionPath = Join-Path $installRoot "egs-sync-transaction"
    $stagePath = Join-Path $installRoot "egs-programdata-stage"
    $backupRoot = Join-Path $installRoot "egs-programdata-backups"
    if (Test-Path -LiteralPath $transactionPath) {
        Restore-ClientEgsTransaction -TransactionPath $transactionPath
    }
    Assert-ClientEgsAggressiveLocalTargetsSafe -ProgramDataPath $ProgramDataPath `
        -LauncherInstalledPath $LauncherInstalledPath `
        -SharedInstallDbPath $SharedInstallDbPath

    $bundleSet = Read-ClientEgsAggressiveBundles -ExpectedVolumes $ExpectedVolumes `
        -ConfigRevision $ConfigRevision
    $index = Read-ClientEgsAggressiveIndex -Path $bundleSet.IndexPath `
        -ArchiveMetadata $bundleSet.ArchiveMetadata
    if ([string]$index.TreeSha256 -ne [string]$bundleSet.ArchiveMetadata.tree_sha256) {
        throw "Epic Games aggressive tree hash does not match the bundles"
    }
    if (-not (Test-Path -LiteralPath $bundleSet.ArchivePath -PathType Leaf) -or
        [Int64](Get-Item -LiteralPath $bundleSet.ArchivePath).Length -ne
            [Int64]$bundleSet.ArchiveMetadata.archive_length -or
        (Get-EgsFileSha256Hex -Path $bundleSet.ArchivePath) -ne
            [string]$bundleSet.ArchiveMetadata.archive_sha256) {
        throw "Epic Games aggressive archive hash verification failed"
    }
    $manifestDirectory = Join-Path $ProgramDataPath "Manifests"
    $alreadyCurrent = $false
    if (Test-Path -LiteralPath $aggressiveStatePath -PathType Leaf) {
        try {
            $currentState = Get-Content -LiteralPath $aggressiveStatePath -Raw | ConvertFrom-Json
            if ([int]$currentState.schema_version -eq 2 -and
                [string]$currentState.tree_sha256 -eq [string]$index.TreeSha256 -and
                [string]$currentState.archive_sha256 -eq
                    [string]$bundleSet.ArchiveMetadata.archive_sha256) {
                Assert-ClientEgsAggressiveTree -IndexData $index `
                    -ProgramDataPath $ProgramDataPath `
                    -LauncherInstalledPath $LauncherInstalledPath `
                    -SharedInstallDbPath $SharedInstallDbPath
                Assert-ClientEgsAggressiveInventory -ManifestDirectory $manifestDirectory `
                    -Desired $bundleSet.Desired
                Assert-ClientEgsAggressiveManagedState -Path $statePath `
                    -Desired $bundleSet.Desired
                $alreadyCurrent = $true
            }
        } catch { $alreadyCurrent = $false }
    }
    if (-not $alreadyCurrent) {
        Expand-ClientEgsAggressiveArchive -ArchivePath $bundleSet.ArchivePath `
            -ArchiveMetadata $bundleSet.ArchiveMetadata -IndexData $index `
            -StagePath $stagePath
        $stageDataPath = Join-Path $stagePath "EpicGamesLauncher\Data"
        $stageLauncherPath = Join-Path $stagePath `
            "UnrealEngineLauncher\LauncherInstalled.dat"
        $stageSharedInstallDbPath = Join-Path $stagePath `
            "EpicOnlineServicesShared\InstallHelper\InstalledItems"
        Assert-ClientEgsAggressiveTree -IndexData $index `
            -ProgramDataPath $stageDataPath -LauncherInstalledPath $stageLauncherPath `
            -SharedInstallDbPath $stageSharedInstallDbPath
        Assert-ClientEgsAggressiveInventory `
            -ManifestDirectory (Join-Path $stageDataPath "Manifests") `
            -Desired $bundleSet.Desired

        $journal = Start-ClientEgsAggressiveTransaction `
            -TransactionPath $transactionPath -ProgramDataPath $ProgramDataPath `
            -LauncherInstalledPath $LauncherInstalledPath `
            -SharedInstallDbPath $SharedInstallDbPath -StatePath $statePath `
            -AggressiveStatePath $aggressiveStatePath -StagePath $stagePath
        try {
            Assert-EgsLauncherStopped
            Wait-EgsSharedInstallDbIdle -InstallDbPath $SharedInstallDbPath
            if ([bool]$journal.data_existed) {
                Move-Item -LiteralPath $ProgramDataPath `
                    -Destination (Join-Path $transactionPath "backup\Data")
            }
            if ([bool]$journal.shared_install_db_existed) {
                Move-Item -LiteralPath $SharedInstallDbPath `
                    -Destination (Join-Path $transactionPath "backup\SharedInstallDb")
            }
            Save-ClientEgsAggressiveBackup -TransactionPath $transactionPath `
                -BackupRoot $backupRoot -Journal $journal | Out-Null
            $dataParent = Split-Path $ProgramDataPath -Parent
            if (-not (Test-Path -LiteralPath $dataParent)) {
                New-Item -ItemType Directory -Path $dataParent -Force | Out-Null
            }
            Move-Item -LiteralPath $stageDataPath -Destination $ProgramDataPath
            Reset-ClientEgsInheritedAcl -Path $ProgramDataPath
            $sharedParent = Split-Path $SharedInstallDbPath -Parent
            if (-not (Test-Path -LiteralPath $sharedParent)) {
                New-Item -ItemType Directory -Path $sharedParent -Force | Out-Null
            }
            Move-Item -LiteralPath $stageSharedInstallDbPath `
                -Destination $SharedInstallDbPath
            Reset-ClientEgsInheritedAcl -Path $SharedInstallDbPath
            Write-EgsBytesAtomic -Path $LauncherInstalledPath `
                -Bytes ([IO.File]::ReadAllBytes($stageLauncherPath))
            Write-ClientEgsManagedState -Path $statePath -Desired $bundleSet.Desired
            $aggressiveState = [ordered]@{
                schema_version = 2
                tree_sha256 = [string]$index.TreeSha256
                archive_sha256 = [string]$bundleSet.ArchiveMetadata.archive_sha256
                file_count = [int]$index.FileCount
                total_bytes = [Int64]$index.TotalBytes
            } | ConvertTo-Json -Depth 3
            Write-EgsBytesAtomic -Path $aggressiveStatePath `
                -Bytes ([Text.Encoding]::UTF8.GetBytes($aggressiveState))
            Assert-EgsLauncherStopped
            Wait-EgsSharedInstallDbIdle -InstallDbPath $SharedInstallDbPath
            Assert-ClientEgsAggressiveTree -IndexData $index `
                -ProgramDataPath $ProgramDataPath `
                -LauncherInstalledPath $LauncherInstalledPath `
                -SharedInstallDbPath $SharedInstallDbPath
            Assert-ClientEgsAggressiveInventory -ManifestDirectory $manifestDirectory `
                -Desired $bundleSet.Desired
            Assert-ClientEgsAggressiveManagedState -Path $statePath `
                -Desired $bundleSet.Desired
            Remove-Item -LiteralPath $stagePath -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $transactionPath -Recurse -Force
        } catch {
            $failure = $_
            try { Stop-EgsLauncherProcesses } catch { }
            try {
                Wait-EgsSharedInstallDbIdle -InstallDbPath $SharedInstallDbPath
                Restore-ClientEgsTransaction -TransactionPath $transactionPath
            } catch {
                throw "Epic Games aggressive sync failed and rollback did not complete: $($_.Exception.Message)"
            }
            throw $failure
        }
    }
    $warningCount = 0
    foreach ($entry in $bundleSet.Desired) {
        $warningCount += @($entry.StateWarnings).Count
    }
    $sharedFiles = @($index.Files | Where-Object {
        $_.RelativePath.StartsWith(
            "EpicOnlineServicesShared/InstallHelper/InstalledItems/",
            [StringComparison]::Ordinal
        )
    })
    $sharedBytes = [Int64]0
    foreach ($entry in $sharedFiles) { $sharedBytes += [Int64]$entry.Length }
    return [pscustomobject]@{
        ManifestCount = @($bundleSet.Desired).Count
        FileCount = [int]$index.FileCount
        TotalBytes = [Int64]$index.TotalBytes
        SharedInstallDbFileCount = $sharedFiles.Count
        SharedInstallDbTotalBytes = $sharedBytes
        Changed = -not $alreadyCurrent
        IncompleteWarningCount = $warningCount
    }
}

function Invoke-ResetMain {
    param(
        [string]$BaseUrl,
        [string]$ClientTokenPath,
        [string]$SyncConfigPath = "",
        [string]$MajesticSettingsConfigPath = "",
        [string]$Gta5RpSettingsConfigPath = "",
        [int]$TimeoutSeconds
    )
    $SyncConfigPath = Resolve-EgsSyncConfigPath -Path $SyncConfigPath
    $MajesticSettingsConfigPath = Resolve-MajesticSyncConfigPath `
        -Path $MajesticSettingsConfigPath
    $Gta5RpSettingsConfigPath = Resolve-Gta5RpSyncConfigPath `
        -Path $Gta5RpSettingsConfigPath
    $requestId = [Guid]::NewGuid().ToString("D")
    $connectedTarget = ""
    $stage = "startup"
    try {
        Write-ResetProgress -RequestId $requestId -Event "start" `
            -Message "Client reset task started"
        if (-not (Test-Path -LiteralPath $ClientTokenPath)) { throw "Token file not found" }
        $token = (Get-Content -LiteralPath $ClientTokenPath -Raw).Trim()
        if ([string]::IsNullOrWhiteSpace($token)) { throw "Token file is empty" }
        if ($BaseUrl.StartsWith("http://") -and
            ([string]::IsNullOrWhiteSpace($script:SimulationStatePath) -or -not $script:AllowHttpForSimulation)) {
            throw "Plain HTTP is permitted only in explicit simulation mode"
        }
        if ([string]::IsNullOrWhiteSpace($script:SimulationStatePath)) {
            Set-Service -Name MSiSCSI -StartupType Automatic
            Start-Service -Name MSiSCSI
        }
        $egsSyncMode = Get-EgsManifestSyncMode -Path $SyncConfigPath
        $health = Wait-ResetApi -BaseUrl $BaseUrl -RequestId $requestId `
            -TimeoutSeconds $TimeoutSeconds
        Write-ResetProgress -RequestId $requestId -Event "api_ready" `
            -Message "Reset API is reachable"
        $stage = "client_configuration"
        $client = Invoke-ResetRequest -Method GET -Uri "$BaseUrl/v1/client" -Token $token -RequestId $requestId
        Write-ResetProgress -RequestId $requestId -Event "client_configuration_loaded" `
            -Message "Client target configuration loaded" -Details @{
                target_iqn = [string]$client.target_iqn
            }
        if (@(Get-ResetSessions -TargetIqn ([string]$client.target_iqn)).Count -gt 0) {
            throw (New-ApiException -StatusCode 409 -Code "LOCAL_SESSION_ACTIVE" -Message "Target is already connected locally")
        }
        $stage = "prepare"
        $prepared = Invoke-PrepareWithRetry -BaseUrl $BaseUrl -Token $token -RequestId $requestId -TimeoutSeconds $TimeoutSeconds
        Write-ResetProgress -RequestId $requestId -Event "prepared" `
            -Message "Server prepared the complete client volume set" -Details @{
                target_iqn = [string]$prepared.target_iqn
                volume_count = @($prepared.volumes).Count
            }
        $stage = "connect"
        Ensure-ResetPortal -Portal $prepared.portal
        Wait-ResetTargetDiscovery -TargetIqn ([string]$prepared.target_iqn) `
            -Portal $prepared.portal -RequestId $requestId | Out-Null
        $session = Connect-ResetTarget -TargetIqn ([string]$prepared.target_iqn) -Portal $prepared.portal
        $connectedTarget = [string]$prepared.target_iqn
        Write-ResetProgress -RequestId $requestId -Event "target_connected" `
            -Message "Created a non-persistent iSCSI session" -Details @{
                target_iqn = $connectedTarget
            }
        $stage = "disk_validation"
        $disks = @(Wait-ResetSessionDisks -Session $session -ExpectedCount @($prepared.volumes).Count)
        Mount-ResetVolumes -ExpectedVolumes @($prepared.volumes) -Disks $disks `
            -RequestId $requestId
        try {
            $majesticConfig = Get-MajesticSyncConfig -Path $MajesticSettingsConfigPath
            if ($majesticConfig.Enabled) {
                $majesticResult = Invoke-ClientMajesticSettingsSync `
                    -Config $majesticConfig -ExpectedVolumes @($prepared.volumes) `
                    -ConfigRevision ([string]$health.config_revision)
                Write-ResetProgress -RequestId $requestId `
                    -Event "majestic_settings_sync_ready" `
                    -Message "Majestic Launcher settings match the mounted release" `
                    -Details @{
                        prefs_bytes = [Int64]$majesticResult.PrefsLength
                        verification_hash_map_bytes = [Int64]$majesticResult.HashMapLength
                        general_hash_map_bytes = [Int64]$majesticResult.HashMapGeneralLength
                        backup_file_count = [int]$majesticResult.BackupFileCount
                        backup_total_bytes = [Int64]$majesticResult.BackupTotalBytes
                        file_count = [int]$majesticResult.FileCount
                        registry_value_count = [int]$majesticResult.RegistryValueCount
                    }
            }
        } catch {
            Write-ResetLog -Level "WARN" -Event "majestic_settings_sync_warning" `
                -RequestId $requestId `
                -Message "Majestic Launcher settings were not applied" `
                -Details @{ stage = "majestic_settings_sync" }
        }
        try {
            $gta5RpConfig = Get-Gta5RpSyncConfig -Path $Gta5RpSettingsConfigPath
            if ($gta5RpConfig.Enabled) {
                $gta5RpResult = Invoke-ClientGta5RpSettingsSync `
                    -Config $gta5RpConfig -ExpectedVolumes @($prepared.volumes) `
                    -ConfigRevision ([string]$health.config_revision)
                Write-ResetProgress -RequestId $requestId `
                    -Event "gta5rp_settings_sync_ready" `
                    -Message "GTA5RP Launcher settings match the mounted release" `
                    -Details @{
                        registry_tree_count = [int]$gta5RpResult.TreeCount
                        registry_key_count = [int]$gta5RpResult.KeyCount
                        registry_value_count = [int]$gta5RpResult.ValueCount
                        registry_data_bytes = [int64]$gta5RpResult.TotalDataBytes
                    }
            }
        } catch {
            Write-ResetLog -Level "WARN" -Event "gta5rp_settings_sync_warning" `
                -RequestId $requestId `
                -Message "GTA5RP Launcher settings were not applied" `
                -Details @{ stage = "gta5rp_settings_sync" }
        }
        if ($egsSyncMode -ne "Disabled") {
            $stage = "egs_manifest_sync"
            try {
                if ($egsSyncMode -eq "Aggressive") {
                    $syncResult = Invoke-ClientEgsAggressiveSync `
                        -ExpectedVolumes @($prepared.volumes) `
                        -ConfigRevision ([string]$health.config_revision) `
                        -SyncConfigPath $SyncConfigPath
                    Write-ResetProgress -RequestId $requestId `
                        -Event "egs_eos_install_db_sync_ready" `
                        -Message "Epic Games EOS shared installation database matches the mounted release" `
                        -Details @{
                            file_count = [int]$syncResult.SharedInstallDbFileCount
                            total_bytes = [Int64]$syncResult.SharedInstallDbTotalBytes
                        }
                    Write-ResetProgress -RequestId $requestId `
                        -Event "egs_programdata_sync_ready" `
                        -Message "Epic Games shared ProgramData matches the mounted release" `
                        -Details @{
                            file_count = [int]$syncResult.FileCount
                            game_count = [int]$syncResult.ManifestCount
                            total_bytes = [Int64]$syncResult.TotalBytes
                        }
                } else {
                    $syncResult = Invoke-ClientEgsManifestSync `
                        -ExpectedVolumes @($prepared.volumes) `
                        -ConfigRevision ([string]$health.config_revision) `
                        -SyncConfigPath $SyncConfigPath
                }
                if ($egsSyncMode -eq "Enabled" -and
                    ($syncResult.AdoptedAppCount -gt 0 -or
                    $syncResult.DisplacedManifestCount -gt 0 -or
                    $syncResult.LauncherEntryRemovalCount -gt 0)) {
                    Write-ResetProgress -RequestId $requestId `
                        -Event "egs_registration_takeover" `
                        -Message "Epic Games registrations were switched to the mounted release" `
                        -Details @{
                            adopted_app_count = [int]$syncResult.AdoptedAppCount
                            displaced_manifest_count = [int]$syncResult.DisplacedManifestCount
                            launcher_entry_removal_count = [int]$syncResult.LauncherEntryRemovalCount
                        }
                }
                if ($egsSyncMode -eq "Enabled") {
                    Write-ResetProgress -RequestId $requestId `
                        -Event "egs_launcher_registration_sync" `
                        -Message "Epic Games launcher registrations match the mounted release" `
                        -Details @{
                            imported_registration_count = [int]$syncResult.LauncherEntryImportCount
                            item_only_fallback_count = [int]$syncResult.LauncherFallbackAppCount
                            incomplete_warning_count = [int]$syncResult.IncompleteWarningCount
                        }
                }
                Write-ResetProgress -RequestId $requestId -Event "egs_manifest_sync_ready" `
                    -Message "Epic Games manifests match the mounted release" -Details @{
                        manifest_count = [int]$syncResult.ManifestCount
                    }
            } catch {
                Write-ResetLog -Level "WARN" -Event "egs_manifest_sync_warning" `
                    -RequestId $requestId `
                    -Message "Epic Games state was not synchronized" `
                    -Details @{ stage = "egs_manifest_sync" }
            }
        }
        Write-ResetLog -Level "INFO" -Event "ready" -RequestId $requestId `
            -Message "Target connected and verified" -Details @{
                target_iqn = $connectedTarget
                volume_count = @($prepared.volumes).Count
            }
        return 0
    } catch {
        $failure = $_
        if (-not [string]::IsNullOrWhiteSpace($connectedTarget)) {
            $disconnectVerified = $false
            try {
                Disconnect-ResetTarget -TargetIqn $connectedTarget
                $disconnectVerified = $true
            } catch { }
            if ($disconnectVerified) {
                Write-ResetProgress -RequestId $requestId `
                    -Event "target_disconnected_after_error" `
                    -Message "Disconnected the session created by this run" -Details @{
                        target_iqn = $connectedTarget
                        stage = $stage
                    }
            } else {
                Write-ResetLog -Level "ERROR" -Event "target_disconnect_failed" `
                    -RequestId $requestId `
                    -Message "Could not verify removal of the session created by this run" `
                    -Details @{ target_iqn = $connectedTarget; stage = $stage }
            }
        }
        $code = "CLIENT_ERROR"
        if ($failure.Exception.Data.Contains("Code")) {
            $code = [string]$failure.Exception.Data["Code"]
        }
        Write-ResetLog -Level "ERROR" -Event $code -RequestId $requestId `
            -Message "$stage`: $($failure.Exception.Message)" -Details @{ stage = $stage }
        if ($stage -in @("disk_validation", "connect", "egs_manifest_sync")) { return 40 }
        if ($stage -eq "prepare" -or $stage -eq "client_configuration") { return 20 }
        return 10
    }
}

if (-not $NoMain) {
    $exitCode = Invoke-ResetMain -BaseUrl $ApiBaseUrl -ClientTokenPath $TokenPath `
        -SyncConfigPath $EgsSyncConfigPath `
        -MajesticSettingsConfigPath $MajesticSyncConfigPath `
        -Gta5RpSettingsConfigPath $Gta5RpSyncConfigPath `
        -TimeoutSeconds $WaitTimeoutSeconds
    if ($PassThruExitCode) {
        Write-Output $exitCode
    } else {
        exit $exitCode
    }
}
