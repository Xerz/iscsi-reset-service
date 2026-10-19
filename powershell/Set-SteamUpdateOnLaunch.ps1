#Requires -Version 5.1
<#
.SYNOPSIS
Sets AutoUpdateBehavior to 1 (only update on launch) in installed Steam manifests.
.DESCRIPTION
Close Steam first. Searches SteamLibrary at drive roots, standard Steam install
folders, the registered Steam install, and its libraryfolders.vdf entries.
Each changed manifest gets a unique backup beside it. Supports -WhatIf.
.EXAMPLE
.\Set-SteamUpdateOnLaunch.ps1 -WhatIf
.EXAMPLE
.\Set-SteamUpdateOnLaunch.ps1
.EXAMPLE
.\Set-SteamUpdateOnLaunch.ps1 -LibraryPath 'D:\SteamLibrary', 'E:\Games\Steam'
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    # When supplied, process only these library roots (the parent of steamapps).
    [string[]]$LibraryPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$utf8 = [System.Text.UTF8Encoding]::new($false, $true)

function Assert-SteamClosed {
    if (Get-Process -Name steam -ErrorAction SilentlyContinue) {
        throw 'Exit Steam completely (Steam > Exit), then run this script again.'
    }
}

if (-not $WhatIfPreference) { Assert-SteamClosed }

$roots = [System.Collections.Generic.List[string]]::new()
if ($LibraryPath) {
    foreach ($path in $LibraryPath) { $roots.Add($path) }
} else {
    foreach ($drive in [System.IO.DriveInfo]::GetDrives()) {
        if (-not $drive.IsReady) { continue }
        foreach ($relative in @('SteamLibrary', 'Program Files (x86)\Steam', 'Program Files\Steam')) {
            $roots.Add((Join-Path $drive.RootDirectory.FullName $relative))
        }
    }
    foreach ($key in @(
        'HKCU:\Software\Valve\Steam',
        'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam',
        'HKLM:\SOFTWARE\Valve\Steam'
    )) {
        $item = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
        if ($null -eq $item) { continue }
        foreach ($name in @('SteamPath', 'InstallPath')) {
            $property = $item.PSObject.Properties[$name]
            if ($null -ne $property -and $property.Value) {
                $roots.Add([string]$property.Value)
            }
        }
    }

    # Include registered libraries in nonstandard locations, too.
    foreach ($root in @($roots.ToArray())) {
        $vdf = Join-Path $root 'steamapps\libraryfolders.vdf'
        if (-not (Test-Path -LiteralPath $vdf -PathType Leaf)) { continue }
        $libraryText = [System.IO.File]::ReadAllText($vdf, $utf8)
        foreach ($match in [regex]::Matches($libraryText, '"path"\s+"([^"\r\n]+)"')) {
            $roots.Add($match.Groups[1].Value.Replace('\\', '\'))
        }
    }
}

$libraries = @(
    foreach ($root in $roots) {
        $steamapps = Join-Path $root 'steamapps'
        if (Test-Path -LiteralPath $steamapps -PathType Container) {
            (Get-Item -LiteralPath $steamapps).FullName
        } elseif ($LibraryPath) {
            throw "Library has no accessible steamapps directory: $root"
        }
    }
) | Sort-Object -Unique
if (-not $libraries) { throw 'No Steam libraries found.' }

$runId = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' + [guid]::NewGuid().ToString('N')
$failed = 0
foreach ($library in $libraries) {
    foreach ($file in Get-ChildItem -LiteralPath $library -Filter 'appmanifest_*.acf' -File) {
        if ($file.Name -notmatch '^appmanifest_[0-9]+\.acf$') { continue }
        $temporary = $null
        try {
            # Decode bytes directly: ReadAllText would silently strip an existing BOM.
            $text = $utf8.GetString([System.IO.File]::ReadAllBytes($file.FullName))
            $header = [regex]::Match($text, '\A\uFEFF?\s*"AppState"\s*\{[ \t]*(?:\r?\n)')
            if (-not $header.Success -or $text -notmatch '\}\s*\z') {
                throw 'Unrecognized AppState manifest; left unchanged.'
            }
            $pattern = '(?m)^([ \t]*"AutoUpdateBehavior"[ \t]+")([0-9]+)("[ \t]*\r?$)'
            $matches = [regex]::Matches($text, $pattern)
            if ($matches.Count -gt 1 -or (
                $matches.Count -eq 0 -and $text.Contains('"AutoUpdateBehavior"')
            )) {
                throw 'Ambiguous AutoUpdateBehavior field; left unchanged.'
            }
            if ($matches.Count -eq 1) {
                $value = $matches[0].Groups[2]
                if ($value.Value -eq '1') {
                    [pscustomobject]@{ Path = $file.FullName; Status = 'Unchanged'; Backup = $null }
                    continue
                }
                $updated = $text.Remove($value.Index, $value.Length).Insert($value.Index, '1')
            } else {
                $newline = "`n"
                if ($header.Value.EndsWith("`r`n")) { $newline = "`r`n" }
                $updated = $text.Insert($header.Length, "`t`"AutoUpdateBehavior`"`t`t`"1`"$newline")
            }

            if ($PSCmdlet.ShouldProcess($file.FullName, 'Set AutoUpdateBehavior=1 with backup')) {
                Assert-SteamClosed
                $backup = $file.FullName + '.bak.' + $runId
                $temporary = $file.FullName + '.tmp.' + $runId
                [System.IO.File]::WriteAllText($temporary, $updated, $utf8)
                # Abort if Steam or another process changed the manifest since reading it.
                Assert-SteamClosed
                $current = $utf8.GetString([System.IO.File]::ReadAllBytes($file.FullName))
                if ($current -cne $text) {
                    throw 'Manifest changed while processing; left unchanged.'
                }
                [System.IO.File]::Replace($temporary, $file.FullName, $backup)
                [pscustomobject]@{ Path = $file.FullName; Status = 'Changed'; Backup = $backup }
            }
        } catch {
            $failed++
            Write-Warning ("{0}: {1}" -f $file.FullName, $_.Exception.Message)
        } finally {
            if ($temporary -and [System.IO.File]::Exists($temporary)) {
                [System.IO.File]::Delete($temporary)
            }
        }
    }
}
if ($failed -gt 0) { throw "$failed manifest(s) could not be updated; see warnings above." }
